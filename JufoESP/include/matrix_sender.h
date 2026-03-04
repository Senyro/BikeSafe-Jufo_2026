// ============================================================
//  matrix_sender.h  ·  ESP32 → Raspberry Pi matrix protocol
//  JUFO-BIKE  ·  ESP32
//
//  Evaluates sensor distances against configurable thresholds
//  and sends edge-triggered warning codes over Serial to the Pi.
//
//  Protocol:  "W<digit>\n"  (one ASCII line per state change)
//    W0  –  clear / idle
//    W1  –  car overtaking too closely  (left sensor triggered)
//    W2  –  car following too closely   (rear sensor triggered)
// ============================================================
#pragma once

#include <stdint.h>

// ── Thresholds ───────────────────────────────────────────────
// Adjust these to match the safety distances defined in the app.
// Units: centimetres.

/** Left (overtaking) sensor: trigger if object closer than this. */
#define MATRIX_THRESH_LEFT_CM   150u   // 1.50 m  (legal min overtaking distance)

/** Rear (tailgating) sensor: trigger if object closer than this. */
#define MATRIX_THRESH_REAR_CM   300u   // 3.00 m  (safe following distance at 30 km/h)

// ── Public API ───────────────────────────────────────────────

/**
 * Initialise the matrix sender.
 * Must be called once from setup(), AFTER Serial.begin().
 * Sends W0 immediately so the Pi starts in the clear state.
 */
void matrixSenderInit();

/**
 * Evaluate current sensor distances and, if the warning state has
 * changed, send the corresponding W-code over Serial.
 *
 * Call this periodically from the BLE notify task (or any periodic
 * task); the function is non-blocking and internally edge-triggered.
 *
 * @param leftCm   Latest left-side distance in cm (DIST_FAULT → 0xFFFF).
 * @param rearCm   Latest rear distance in cm       (DIST_FAULT → 0xFFFF).
 */
void matrixSenderUpdate(uint16_t leftCm, uint16_t rearCm);
