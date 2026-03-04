// ============================================================
//  matrix_sender.cpp  ·  ESP32 → Raspberry Pi matrix protocol
//  JUFO-BIKE  ·  ESP32
//
//  State machine
//  ─────────────
//  Priority order (highest first):
//    1. W1 – left sensor below MATRIX_THRESH_LEFT_CM
//    2. W2 – rear sensor below MATRIX_THRESH_REAR_CM
//    3. W0 – no active warning
//
//  A message is sent ONLY when the state changes (edge-triggered).
//  DIST_FAULT (0xFFFF) is treated as "no object detected" so that a
//  disconnected sensor does not produce a spurious warning.
// ============================================================
#include "matrix_sender.h"
#include "sensor.h" // DIST_FAULT

#include <Arduino.h>

// ── Internal state ────────────────────────────────────────────
static uint8_t s_lastCode = 0xFF; // 0xFF = uninitialized, forces W0 on init

// ── Helpers ───────────────────────────────────────────────────
static bool isTriggered(uint16_t distCm, uint16_t threshCm) {
  // DIST_FAULT means sensor offline → treat as safe (no object)
  if (distCm == DIST_FAULT)
    return false;
  return distCm < threshCm;
}

static void sendCode(uint8_t code) {
  // Single ASCII line: "W0\n" … "W9\n"
  // The Pi ignores any other output on this serial port (debug logs etc.)
  Serial.print('W');
  Serial.print(static_cast<char>('0' + code));
  Serial.print('\n');
  Serial.flush(); // ensure the byte is pushed out immediately
  Serial.printf("[Matrix] sent W%u\n", code);
}

// ── Public API ────────────────────────────────────────────────
void matrixSenderInit() {
  // Force the first update() call to transmit W0
  s_lastCode = 0xFF;
  matrixSenderUpdate(DIST_FAULT, DIST_FAULT);
}

void matrixSenderUpdate(uint16_t leftCm, uint16_t rearCm) {
  uint8_t code;

  if (isTriggered(leftCm, MATRIX_THRESH_LEFT_CM)) {
    code = 1; // W1: overtaking too closely
  } else if (isTriggered(rearCm, MATRIX_THRESH_REAR_CM)) {
    code = 2; // W2: following too closely
  } else {
    code = 0; // W0: clear
  }

  // Edge-triggered: only transmit when state changes
  if (code != s_lastCode) {
    sendCode(code);
    s_lastCode = code;
  }
}

void matrixSenderForce(uint8_t code) {
  // Always send the code (not edge-triggered), then update s_lastCode so the
  // next sensor-based call sees the correct previous state.
  sendCode(code);
  s_lastCode = code;
}
