# kienzlelock

Kompakte README für Installation, Betrieb und Notfallzugriff.

## Zweck

`kienzlelock` ist ein schneller, tagbasierter Vorschalt-Lockscreen für Linux/XFCE mit LightDM-Autologin.
Die Benutzer-Session läuft nach dem Autologin bereits vollständig im Hintergrund. Es findet **kein echter Re-Login** statt. Die Sperre wird nur darübergelegt.

## Zielplattform

- Ubuntu LTS
- X11 / XFCE
- LightDM mit Autologin
- lokaler HTTPS-Webserver auf `127.0.0.1:8443`
- nativer Overlay-Lockscreen
- PC/SC-basierter Reader-Zugriff

## Installation

Installer als root ausführen:

```bash
chmod +x install_kienzlelock.sh
sudo bash install_kienzlelock.sh
```

Danach:

1. LightDM-Autologin und XFCE normal starten lassen
2. `kienzlelockd` prüfen
3. lokale Registrierungsseite öffnen

Status prüfen:

```bash
sudo systemctl --no-pager --full status kienzlelockd
sudo ss -ltnp | grep 8443 || true
```

Registrierungsseite lokal am Gerät öffnen:

```text
https://127.0.0.1:8443/register
```

## Grundprinzip

- Die Session bleibt offen.
- Programme bleiben offen.
- Der native Overlay-Lockscreen blockiert die Bedienung.
- Ein gültiger Tag löst abhängig vom Zustand aus:
  - **gesperrt** -> Benutzer erkennen, ggf. PIN verlangen, dann freigeben
  - **offen** -> wieder sperren
- Damit arbeitet das System als **Toggle**.

## Komponenten

### 1. Daemon

Systemdienst:

```text
kienzlelockd.service
```

Aufgaben:

- Reader überwachen
- Tags erkennen
- PIN prüfen
- Policies anwenden
- `config.json` lesen
- `state.json` schreiben
- lokale HTTPS-API bereitstellen

### 2. Native Sperr-UI

Der sichtbare Lockscreen ist **nativ**, nicht im sichtbaren Firefox-Kiosk.
Der Browser wird für die Registrierung/Verwaltung genutzt, nicht als eigentliche Sperre.

### 3. Konfiguration

Dauerhafte Konfiguration:

```text
/etc/kienzlelock/config.json
```

Laufzeitzustand:

```text
/var/lib/kienzlelock/state.json
```

## Wichtige Funktionen

- schwarzer Sperrbildschirm
- zentrales Schloss-/NFC-Logo
- Begrüßung nach Tagkontakt
- PIN-Abfrage bei Bedarf
- 4 Fehlversuche
- danach 10 Minuten Sperre
- Reauth-Fenster standardmäßig 8 Stunden
- Registrierungsseite mit Passwortschutz
- bestehende Registrierungen können bearbeitet und gelöscht werden

## Reader / Tags

### Aktuell verwendete Tags

Im bisherigen Aufbau wurden einfache kontaktlose UID-Tags am **ACS ACR122U** genutzt.
Auf deinem System waren das ISO14443A-Tags mit 4-Byte-UID, passend zu einfachen MIFARE-Classic-/kompatiblen Transpondern.

Beispielhafte Ausgabe sah so aus:

- `ATQA 00 04`
- `SAK 08`
- 4-Byte-UID

Das passt gut zu einfachen Karten oder Schlüsselanhängern, wie sie bei MIFARE-Classic-1K-kompatiblen Medien häufig vorkommen.

### Was außerdem unterstützt wird

Der aktuelle Stand ist pragmatisch PC/SC-basiert:

- **ACR122U PICC** für UID-basierte kontaktlose Tags - leider muss man ihn zur korrekten Initialisierung einmal abziehen und Stecken
- **YubiKey per USB-CCID** auf derselben PC/SC-Basis, wenn der YubiKey als Reader erscheint
- Unterstützung für den als Stabil geltenden **Sony RC-S380/S**

Wichtig:

- Bei NFC-Tags arbeitet `kienzlelock` aktuell pragmatisch mit **UID-basierter Zuordnung**.
- Bei YubiKeys wird aktuell ebenfalls derselbe PC/SC-Weg genutzt.
- Andere Tags können funktionieren, wenn sie vom ACR122U sauber gelesen werden und eine stabile Kennung liefern.

### Was praktisch gut geeignet ist

- einfache kontaktlose Karten oder Keyfobs für den Alltag
- mehrere Tags pro Benutzer
- separater Test-Tag für Entwicklung/Recovery

## Registrierung

Registrierung lokal im Browser:

```text
https://127.0.0.1:8443/register
```

Ablauf:

1. Admin-Login mit Registrierungs-Passwort
2. Registrierungsmodus starten
3. neuen Tag gegenhalten
4. Benutzer, Label, PIN und optionales Reauth-Fenster speichern

## Registrierungs-Passwort zurücksetzen

Das folgende Beispiel setzt das Registrierungs-Passwort auf:

```text
kienzlelock-reset
```

```bash
sudo systemctl stop kienzlelockd || true

NEW_HASH="$(sudo python3 - <<'PY'
import runpy
ns = runpy.run_path('/opt/kienzlelock/daemon.py')
print(ns['make_hash']('kienzlelock-reset'))
PY
)"

sudo python3 - <<PY
import json
p = '/etc/kienzlelock/config.json'
with open(p, 'r', encoding='utf-8') as f:
    cfg = json.load(f)
cfg.setdefault('admin', {})['registration_password_hash'] = '''$NEW_HASH'''
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
print('registration password reset ok')
PY

sudo systemctl start kienzlelockd
```

## Notfall: wenn man ausgesperrt ist

### Nur Overlay und Overlay-Starter beenden

```bash
sudo pkill -f '/opt/kienzlelock/overlay.py' || true
sudo pkill -f 'kienzlelock-overlay-launcher.sh' || true
```

### Zusätzlich den Daemon stoppen

```bash
sudo systemctl stop kienzlelockd || true
```

### Vollständiger Not-Aus für die Sperrkomponenten

```bash
sudo pkill -f '/opt/kienzlelock/overlay.py' || true
sudo pkill -f 'kienzlelock-overlay-launcher.sh' || true
sudo pkill -f 'kienzlelock-browser-controller.sh' || true
sudo pkill -f 'firefox.*127.0.0.1:8443/lock' || true
sudo systemctl stop kienzlelockd || true
```

### Overlay-Autostart vorübergehend deaktivieren

```bash
sudo mv /etc/xdg/autostart/kienzlelock-overlay.desktop /etc/xdg/autostart/kienzlelock-overlay.desktop.off 2>/dev/null || true
mv ~/.config/autostart/kienzlelock-overlay.desktop ~/.config/autostart/kienzlelock-overlay.desktop.off 2>/dev/null || true
```

## Nützliche Prüfkommandos

Daemon-Status:

```bash
sudo systemctl --no-pager --full status kienzlelockd
journalctl -u kienzlelockd -n 80 --no-pager
```

Reader-Status in `state.json`:

```bash
cat /var/lib/kienzlelock/state.json
```

Konfiguration prüfen:

```bash
sudo jq . /etc/kienzlelock/config.json
```

PC/SC-Reader prüfen:

```bash
pcsc_scan
```

## Hinweise

- Die Weboberfläche ist standardmäßig nur lokal auf `127.0.0.1` erreichbar.
- Der sichtbare Lockscreen ist nativ; ein fehlender Sperrbildschirm liegt daher meist am Overlay-Start, nicht am Browser.
- Für produktiven Einsatz ist es sinnvoll, immer mindestens einen zweiten funktionierenden Test-Tag und einen Konsolenzugang bereitzuhalten.
