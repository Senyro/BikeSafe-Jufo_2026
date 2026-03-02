# JUFO-BIKE · Fahrradsicherheitssystem

Ein Echtzeit-Abstandswarnsystem für Fahrräder mit zwei TFMini-S LiDAR-Sensoren, ESP32 und einer Flutter-App.

---

## Projektübersicht

| Komponente | Technologie | Aufgabe |
|---|---|---|
| **JUFO-BIKE (ESP32)** | PlatformIO · NimBLE-Arduino v2.x | Sensoren lesen, BLE-Server, Daten senden |
| **JufoApp (Flutter)** | Flutter · flutter_blue_plus · Riverpod 3 | BLE-Client, GPS, Sicherheitsbewertung, UI |

### Messprinzip
- **Linker Sensor:** Misst den Abstand zu überholenden Fahrzeugen (Seite)
- **Hinterer Sensor:** Misst den Abstand zu nachfolgendem Verkehr (hinten)
- Die App klassifiziert die Situation als **Urban / Rural** (basierend auf GPS-Geschwindigkeit > 50 km/h) und berechnet dynamische Warnschwellen

---

## Repository-Struktur

```
Jufo/
├── JufoESP/                    # ESP32 PlatformIO Projekt
│   ├── platformio.ini          # Board-Konfiguration, Library-Deps
│   ├── include/
│   │   ├── sensor.h            # TFMini-S Pin-Mapping, API
│   │   └── ble_server.h        # BLE UUIDs, Gerätename, API
│   └── src/
│       ├── sensor.cpp          # Sensor-Task (Core 1), Medianfilter
│       ├── ble_server.cpp      # NimBLE GATT-Server
│       └── main.cpp            # Setup, Tasks starten
│
├── JufoApp/                    # Flutter Android-App
│   ├── lib/
│   │   ├── main.dart           # App-Einstiegspunkt, Riverpod-Root
│   │   ├── core/
│   │   │   ├── ble_repository.dart        # BLE-Client (Notifier)
│   │   │   ├── location_repository.dart   # GPS, Geschwindigkeit
│   │   │   ├── distance_evaluator.dart    # Sicherheitsbewertung
│   │   │   └── debug_provider.dart        # Simulationsmodus
│   │   └── ui/
│   │       ├── dashboard_screen.dart      # Hauptanzeige
│   │       ├── connection_screen.dart     # BLE-Verbindung
│   │       └── debug_screen.dart          # Debug/Simulation
│   └── pubspec.yaml
│
└── NimBLE-Arduino-master/      # NimBLE Bibliothek (Referenz/Docs)
```

---

## Hardware-Setup

### Komponenten
- ESP32 DevKit (38-Pin)
- 2× TFMini-S LiDAR-Sensor
- Powerbank oder Akku (5 V)
- Montagematerial am Fahrrad

### Pin-Belegung (ESP32)

| Sensor | Pin | Funktion |
|---|---|---|
| **Linker Sensor** | GPIO 4 | RX (Daten vom Sensor) |
| **Linker Sensor** | GPIO 5 | TX (nicht genutzt, Sensor sendet nur) |
| **Hinterer Sensor** | GPIO 16 | RX |
| **Hinterer Sensor** | GPIO 17 | TX |

> **Wichtig:** TFMini-S läuft auf **3.3 V Logik** – direkt an ESP32 anschliessbar. Versorgung mit 5 V (VCC-Pin des Sensors).

### TFMini-S Messbereich
| Parameter | Wert |
|---|---|
| Mindestabstand | **~10 cm** |
| Maximalabstand | **1200 cm (12 m)** |
| Messrate | 100 Hz |

> ⚠️ **Objekte näher als ~10 cm** werden vom Sensor **nicht korrekt gemessen** und liefern den Maximalwert (1200 cm) oder 0. Der Code behandelt beide Werte als Messfehler (`DIST_FAULT`).

---

## BLE-Protokoll

### GATT-Service
**Service UUID:** `19B10000-E8F2-537E-4F6C-D104768A1214`  
**Gerätename:** `JUFO-BIKE`

### Charakteristiken

| Name | UUID | Properties | Payload |
|---|---|---|---|
| **DIST** | `19B10001-...` | READ, NOTIFY | 4 Bytes: `[leftH, leftL, rearH, rearL]` (cm, Big-Endian) |
| **SPEED** | `19B10002-...` | WRITE, WRITE_NR | 2 Bytes: `[speedH, speedL]` (cm/s, Big-Endian) |

### Datenwerte
- `0xFFFF` = `DIST_FAULT` – Sensor offline, Kabel getrennt oder Messfehler
- `0x04B0` = 1200 cm = Maximalreichweite (kein Objekt erkannt)
- Normale Werte: `10` – `1199` cm

---

## Sicherheitsbewertung (Flutter-App)

### Klasssifizierung: Urban / Rural
| Kontext | Bedingung |
|---|---|
| **Urban** | GPS-Geschwindigkeit < 50 km/h |
| **Rural** | GPS-Geschwindigkeit ≥ 50 km/h |

### Linker Sensor (Überholabstand)

| Zustand | Urban | Rural |
|---|---|---|
| **ALARM** | < 150 cm | < 200 cm |
| **WARNING** | < 200 cm | < 250 cm |
| **SAFE** | ≥ 200 cm | ≥ 250 cm |

*(StVO: Mindestabstand 1,5 m innerorts · 2,0 m außerorts)*

### Hinterer Sensor (Folgeabstand)
Dynamische Schwelle: **Geschwindigkeit × 2 Sekunden**, mindestens 2 m.

| Geschwindigkeit | Alarmschwelle | Warnschwelle |
|---|---|---|
| 0 km/h (Minimum) | 200 cm | 400 cm |
| 30 km/h | 1667 cm | 3667 cm |
| 50 km/h | 2778 cm | 4778 cm |

---

## Sensor-Filterung

Der ESP32 wendet einen **Medianfilter** auf die letzten 9 Messwerte (~180 ms) an:

### Warum Median?
- **Ausreißer werden vollständig eliminiert** – ein einzelner falscher Wert (z.B. 1200 cm bei Nahfeld-Fehler) hat keinen Einfluss
- **Keine Überglättung** – ein 9er-Fenster ist schnell genug für Überholereignisse (~0,5 s bei Autogeschwindigkeit)
- Validierungsregel: Mindestens 5 von 9 Messwerten müssen im gültigen Bereich liegen [10–1199 cm]

### Was wird als **ungültig** erkannt?
| Wert | Ursache | Behandlung |
|---|---|---|
| `0` | Kein Frame empfangen / Checksumfehler | Aus Median-Fenster ausgeschlossen |
| `≥ 1200` | Objekt zu nah (< 10 cm) oder kein Objekt | Aus Median-Fenster ausgeschlossen |
| Timeout > 500 ms | Sensor-Kabel getrennt | `DIST_FAULT` (0xFFFF) |

---

## Software-Setup

### ESP32 (PlatformIO)

**Voraussetzungen:** VS Code + PlatformIO Extension

```bash
# Projekt öffnen
cd d:\Jufo\JufoESP

# Kompilieren
pio run

# Flashen
pio run --target upload

# Serial Monitor
pio device monitor --baud 115200
```

**Erwartete Boot-Ausgabe:**
```
=== JUFO-BIKE booting ===
[BLE] advertising as "JUFO-BIKE"
[Setup] done – waiting for BLE connections
[BLE] notify task running on core 0
[Sensor] task running on core 1
```

### Flutter-App

**Voraussetzungen:** Flutter SDK ≥ 3.x · Android-Gerät mit BLE

```bash
cd d:\Jufo\JufoApp

# Abhängigkeiten holen
flutter pub get

# App installieren und starten (Gerät verbunden)
flutter run
```

**Berechtigungen (Android):** Bluetooth, Bluetooth-Scan, Feinstandort, GPS werden beim ersten Start angefordert.

---

## Betrieb

1. **ESP32 einschalten** → `JUFO-BIKE` wird via BLE gesendet
2. **App öffnen** → Verbindung wird automatisch hergestellt (Service-UUID-Scan)
3. **Auto-Reconnect:** Bei Verbindungsverlust versucht die App alle 3 Sekunden neu zu verbinden
4. **Simulation:** Im Debug-Screen können Abstände und Geschwindigkeit manuell simuliert werden (ohne Hardware)

---

## Abhängigkeiten

### ESP32
| Library | Version | Zweck |
|---|---|---|
| `h2zero/NimBLE-Arduino` | `^2.1.3` | BLE-Stack |

### Flutter
| Package | Version | Zweck |
|---|---|---|
| `flutter_blue_plus` | neueste | BLE-Client |
| `flutter_riverpod` | `^3.2.1` | State Management |
| `geolocator` | neueste | GPS / Geschwindigkeit |
| `wakelock_plus` | neueste | Display eingeschaltet lassen |
| `permission_handler` | neueste | Berechtigungs-Dialog |

---

## Bekannte Einschränkungen

| Problem | Ursache | Status |
|---|---|---|
| TFMini-S misst < 10 cm falsch | Hardware-Mindestabstand | ✅ Gefiltert (Median) |
| Android findet Gerät nicht mit Namensfilter | Android gibt Namen erst nach Verbindung | ✅ Behoben (Service-UUID-Filter) |
| Keine iOS-Unterstützung | flutter_blue_plus erfordert eigene iOS-Konfiguration | ⚠️ Offen |
| Kein Hintergrundmodus | BLE-Scan stoppt wenn App minimiert | ⚠️ Offen |
