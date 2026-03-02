// ============================================================
//  sensor.h  ·  TFMini-S LiDAR interface (2 × UART)
//  JUFO-BIKE  ·  ESP32
// ============================================================
#pragma once

#include <stdint.h>

// ── Pin mapping ──────────────────────────────────────────────
#define SENSOR_LEFT_RX  4
#define SENSOR_LEFT_TX  5
#define SENSOR_REAR_RX 16
#define SENSOR_REAR_TX 17

// ── Distance sentinel: sensor offline / out of range ─────────
#define DIST_FAULT 0xFFFFu   // returned when sensor is unavailable

// ── Public API ───────────────────────────────────────────────
/**
 * Starts the FreeRTOS sensor task on Core 1.
 * Call once from setup() AFTER Serial has been initialised.
 */
void sensorTaskStart();

/** Returns the latest left-side distance in cm (mutex-protected). */
uint16_t sensorGetLeft();

/** Returns the latest rear distance in cm (mutex-protected). */
uint16_t sensorGetRear();
