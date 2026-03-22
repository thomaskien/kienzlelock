#!/usr/bin/env bash

echo ######KARTE AUFLEGEN!!!########


set -u


#REMOVE_PN533=1

VID="072f"
PID="2200"

# Fallback für dein aktuelles System:
# ACR122U hängt laut uhubctl an Hub 2-1, Port 2
KNOWN_HUB="${KNOWN_HUB:-2-1}"
KNOWN_PORT="${KNOWN_PORT:-2}"

POWER_DELAY="${POWER_DELAY:-3}"
STEP_SLEEP="${STEP_SLEEP:-2}"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-4}"

if [[ $EUID -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

find_dev_sysfs() {
  local d v p
  for d in /sys/bus/usb/devices/*; do
    [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
    read -r v < "$d/idVendor"
    read -r p < "$d/idProduct"
    [[ "${v,,}" == "$VID" && "${p,,}" == "$PID" ]] || continue
    basename "$d"
    return 0
  done
  return 1
}

refresh_topology() {
  local dev
  if dev="$(find_dev_sysfs)"; then
    DEV_SYSFS="$dev"
    if [[ "$dev" == *.* ]]; then
      HUB_LOC="${dev%.*}"
      PORT="${dev##*.}"
    else
      HUB_LOC="$KNOWN_HUB"
      PORT="$KNOWN_PORT"
    fi
    return 0
  fi

  DEV_SYSFS=""
  HUB_LOC="$KNOWN_HUB"
  PORT="$KNOWN_PORT"
  return 1
}

reader_present_usb() {
  lsusb | grep -qiE "${VID}:${PID}"
}

reader_present_pcsc() {
  if have pcsc_scan; then
    timeout "$CHECK_TIMEOUT" pcsc_scan -n 2>/dev/null | grep -qiE 'ACR122U|ACS ACR122U|PICC Interface'
    return $?
  fi

  if have opensc-tool; then
    opensc-tool -l 2>/dev/null | grep -qiE 'ACR122U|ACS ACR122U|PICC Interface'
    return $?
  fi

  # Wenn kein PC/SC-Tool da ist, nur USB-Präsenz als Notbehelf
  reader_present_usb
}

reader_ok() {
  reader_present_usb || return 1
  reader_present_pcsc || return 1
  return 0
}

restart_pcscd() {
  $SUDO systemctl restart pcscd 2>/dev/null || true
  $SUDO systemctl restart pcscd.socket 2>/dev/null || true
}

disable_autosuspend() {
  refresh_topology >/dev/null 2>&1 || true
  [[ -n "${DEV_SYSFS:-}" ]] || return 0

  if [[ -w "/sys/bus/usb/devices/$DEV_SYSFS/power/control" ]]; then
    echo on | $SUDO tee "/sys/bus/usb/devices/$DEV_SYSFS/power/control" >/dev/null || true
  fi

  if [[ -w "/sys/bus/usb/devices/$DEV_SYSFS/power/autosuspend_delay_ms" ]]; then
    echo -1 | $SUDO tee "/sys/bus/usb/devices/$DEV_SYSFS/power/autosuspend_delay_ms" >/dev/null || true
  fi
}

authorized_toggle() {
  refresh_topology >/dev/null 2>&1 || true
  [[ -n "${DEV_SYSFS:-}" ]] || return 1
  [[ -w "/sys/bus/usb/devices/$DEV_SYSFS/authorized" ]] || return 1

  log "authorized 0/1 auf $DEV_SYSFS"
  echo 0 | $SUDO tee "/sys/bus/usb/devices/$DEV_SYSFS/authorized" >/dev/null
  sleep 1
  echo 1 | $SUDO tee "/sys/bus/usb/devices/$DEV_SYSFS/authorized" >/dev/null
}

unbind_bind() {
  refresh_topology >/dev/null 2>&1 || true
  [[ -n "${DEV_SYSFS:-}" ]] || return 1

  log "unbind/bind auf $DEV_SYSFS"
  echo "$DEV_SYSFS" | $SUDO tee /sys/bus/usb/drivers/usb/unbind >/dev/null
  sleep 1
  echo "$DEV_SYSFS" | $SUDO tee /sys/bus/usb/drivers/usb/bind >/dev/null
}

power_cycle() {
  [[ -n "${HUB_LOC:-}" && -n "${PORT:-}" ]] || return 1
  have uhubctl || return 1

  log "uhubctl cycle auf Hub $HUB_LOC Port $PORT"
  $SUDO uhubctl -l "$HUB_LOC" -p "$PORT" -a cycle -d "$POWER_DELAY"
}

maybe_remove_pn533() {
  # Optional:
  # REMOVE_PN533=1 ./acr122u-recover-loop.sh
  [[ "${REMOVE_PN533:-0}" == "1" ]] || return 0

  if lsmod | grep -q '^pn533_usb'; then
    log "entferne pn533_usb/pn533/nfc"
    $SUDO modprobe -r pn533_usb pn533 nfc || true
  fi
}

status_dump() {
  log "Status:"
  lsusb | grep -iE "${VID}:${PID}|ACS|ACR122" || true
  refresh_topology >/dev/null 2>&1 || true
  log "DEV_SYSFS=${DEV_SYSFS:-<leer>} HUB=${HUB_LOC:-<leer>} PORT=${PORT:-<leer>}"
}

main() {
  if ! have lsusb; then
    echo "Fehler: lsusb fehlt." >&2
    exit 1
  fi

  if ! have uhubctl; then
    echo "Fehler: uhubctl fehlt." >&2
    exit 1
  fi

  refresh_topology >/dev/null 2>&1 || true
  status_dump
  maybe_remove_pn533
  disable_autosuspend

  local attempt=0
  while true; do
    attempt=$((attempt + 1))
    log "===== Versuch $attempt ====="

    if reader_ok; then
      log "Erfolg: Reader ist im USB- und PC/SC-Stack sichtbar."
      exit 0
    fi

    log "Schritt 1: pcscd neu starten"
    restart_pcscd
    sleep "$STEP_SLEEP"
    if reader_ok; then
      log "Erfolg nach pcscd-Restart."
      exit 0
    fi

    log "Schritt 2: authorized toggeln"
    authorized_toggle || log "authorized-Toggle nicht möglich"
    restart_pcscd
    sleep "$STEP_SLEEP"
    if reader_ok; then
      log "Erfolg nach authorized-Toggle."
      exit 0
    fi

    log "Schritt 3: USB unbind/bind"
    unbind_bind || log "unbind/bind nicht möglich"
    restart_pcscd
    sleep "$STEP_SLEEP"
    if reader_ok; then
      log "Erfolg nach unbind/bind."
      exit 0
    fi

    log "Schritt 4: echter Power-Cycle"
    power_cycle || log "Power-Cycle nicht möglich"
    restart_pcscd
    sleep "$STEP_SLEEP"
    if reader_ok; then
      log "Erfolg nach Power-Cycle."
      exit 0
    fi

    log "Noch kein Erfolg. Nächster Durchlauf in ${STEP_SLEEP}s."
    sleep "$STEP_SLEEP"
  done
}

main "$@"
