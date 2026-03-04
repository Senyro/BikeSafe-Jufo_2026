// ============================================================
//  ble_server.h  ·  NimBLE-Arduino v2.x GATT Server
//  JUFO-BIKE  ·  ESP32
//
//  Service: 19B10000-E8F2-537E-4F6C-D104768A1214
//   ├─ DIST  (19B10001-…) READ | NOTIFY  – 4 bytes: leftH,leftL,rearH,rearL
//   ├─ SPEED (19B10002-…) WRITE | WRITE_NR – 2 bytes: speedH,speedL (cm/s)
//   └─ WARN  (19B10003-…) WRITE | WRITE_NR – 1 byte:
//   0=clear,1=overtake,2=tailgate
// ============================================================
#pragma once

#include <stdbool.h>
#include <stdint.h>

// ── UUIDs (128-bit) ──────────────────────────────────────────
#define BLE_SERVICE_UUID "19B10000-E8F2-537E-4F6C-D104768A1214"
#define BLE_CHAR_DIST "19B10001-E8F2-537E-4F6C-D104768A1214"
#define BLE_CHAR_SPEED "19B10002-E8F2-537E-4F6C-D104768A1214"
#define BLE_CHAR_WARN "19B10003-E8F2-537E-4F6C-D104768A1214"

// ── Advertising device name ───────────────────────────────────
#define BLE_DEVICE_NAME "JUFO-BIKE"

// ── Special values ────────────────────────────────────────────
#define BLE_SPEED_INVALID 0xFFFFu // no valid speed received yet

// ── Public API ────────────────────────────────────────────────
/**
 * Initialise NimBLE, create the GATT server, configure advertising,
 * and start advertising. Call once from setup().
 */
void bleServerInit();

/**
 * Send a NOTIFY packet with the latest sensor distances.
 * Only sends if at least one client is subscribed.
 * @param left  left-side distance in cm (0xFFFF = sensor fault)
 * @param rear  rear distance in cm      (0xFFFF = sensor fault)
 */
void bleNotifyDistances(uint16_t left, uint16_t rear);

/** Returns true if at least one BLE central is connected. */
bool bleIsConnected();

/**
 * Returns the last speed value written by the app, in cm/s.
 * Returns BLE_SPEED_INVALID if no value has been received yet.
 */
uint16_t bleGetSpeedCms();

/**
 * Returns the last warn code written by the app (0, 1, or 2),
 * then resets it to -1 so each write is consumed exactly once.
 * Returns -1 if no new code has been received since the last call.
 */
int8_t bleConsumeWarnCode();
