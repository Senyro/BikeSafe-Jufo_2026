# JUFO-BIKE – LED Matrix Daemon

Displays proximity warnings on the 64 × 64 Joy-IT LED matrix attached to the Raspberry Pi 3 B+.

## Architecture

```
[ESP32]  ──USB-CDC──►  [Raspberry Pi]  ──HUB75──►  [LED Matrix]
         W0/W1/W2\n   matrix_daemon
```

## Prerequisites (Pi)

```bash
# 1. Build the rpi-rgb-led-matrix library (one-time)
cd ../rpi-rgb-led-matrix-master
make -C lib

# 2. Build the daemon
cd ../JufoMatrix
make
```

## Running manually

```bash
sudo ./matrix_daemon
```

The daemon auto-detects `/dev/ttyUSB0` or `/dev/ttyACM0`.
Override with an environment variable:

```bash
sudo MATRIX_SERIAL_PORT=/dev/ttyACM1 ./matrix_daemon
```

## Installing as a systemd service (auto-start at boot)

```bash
sudo make install
# Verify:
systemctl status jufo-matrix
```

To uninstall:

```bash
sudo make uninstall
```

## Warning protocol (ESP32 → Pi over Serial)

| Message | Display |
|---------|---------|
| `W0\n`  | Black screen (idle) |
| `W1\n`  | "Überholabstand beachten" + icon |
| `W2\n`  | "Abstand halten" + icon |

Any other output from the ESP32 (debug `[BLE] …` logs etc.) is silently ignored.

## Tuning thresholds

Overtaking and tailgating thresholds are defined in **`JufoESP/include/matrix_sender.h`**:

```cpp
#define MATRIX_THRESH_LEFT_CM   150u   // 1.50 m  (overtaking)
#define MATRIX_THRESH_REAR_CM   300u   // 3.00 m  (tailgating)
```

Change the values and reflash the ESP32 to take effect.

## File structure

```
d:\Jufo\
├── JufoESP\
│   ├── include\
│   │   ├── matrix_sender.h   ← threshold config & API
│   │   ├── ble_server.h
│   │   └── sensor.h
│   └── src\
│       ├── matrix_sender.cpp ← W-code logic
│       ├── ble_server.cpp
│       ├── sensor.cpp
│       └── main.cpp          ← calls matrixSenderInit/Update
└── JufoMatrix\
    ├── matrix_daemon.cpp     ← Pi daemon (this component)
    └── Makefile
```
