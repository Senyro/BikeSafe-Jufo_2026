// ============================================================
//  main.cpp  ·  JUFO-BIKE  ·  ESP32 BLE Proximity Sensor
//
//  Architecture:
//    sensor.cpp      – TFMini-S LiDAR reading (FreeRTOS, Core 1)
//    ble_server.cpp  – NimBLE-Arduino v2.x GATT Server (Core 0)
//    matrix_sender.cpp – LED matrix protocol → Raspberry Pi (Serial)
//    main.cpp        – FreeRTOS BLE-notify task + Arduino entrypoints
// ============================================================
#include "ble_server.h"
#include "matrix_sender.h"
#include "sensor.h"
#include <Arduino.h>

// ── Prevent Arduino Core 3.x from releasing BT memory ────────
// btInUse() is declared extern "C" in esp32-hal-bt.h
extern "C" bool btInUse() { return true; }

// ── BLE notify rate ───────────────────────────────────────────
static constexpr uint32_t BLE_NOTIFY_HZ = 10; // 10 notifications per second

// ── BLE notify task (Core 0) ─────────────────────────────────
// Reads the latest sensor values and pushes them via BLE NOTIFY.
static void bleNotifyTask(void *) {
  Serial.println("[BLE] notify task running on core 0");
  const TickType_t period = pdMS_TO_TICKS(1000 / BLE_NOTIFY_HZ);

  while (true) {
    const uint16_t leftCm = sensorGetLeft();
    const uint16_t rearCm = sensorGetRear();

    if (bleIsConnected()) {
      bleNotifyDistances(leftCm, rearCm);

      // Optional: log received speed for debugging
      const uint16_t spd = bleGetSpeedCms();
      if (spd != BLE_SPEED_INVALID) {
        // Speed is available; it can be used for on-device logic here
        // e.g. adjust warning thresholds, activate LEDs, etc.
        (void)spd; // suppress unused-variable warning for now
      }
    }

    // Check if the app sent an explicit W-code (debug simulation mode).
    // If so, forward it directly to the Pi and skip sensor evaluation.
    const int8_t appWarn = bleConsumeWarnCode();
    if (appWarn >= 0) {
      matrixSenderForce(static_cast<uint8_t>(appWarn));
    } else {
      // Normal operation: evaluate real sensor distances
      matrixSenderUpdate(leftCm, rearCm);
    }

    vTaskDelay(period);
  }
}

// ── Arduino entry points ──────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(500); // allow USB-serial to enumerate
  Serial.println("\n\n=== JUFO-BIKE booting ===");

  // 1. Start BLE GATT server (advertises immediately)
  bleServerInit();

  // 2. Initialise the LED matrix sender (sends W0 to the Pi)
  matrixSenderInit();

  // 3. Start sensor reading task on Core 1
  sensorTaskStart();

  // 4. Start BLE / matrix notify task on Core 0
  xTaskCreatePinnedToCore(bleNotifyTask, "BLE_Notify", 8192, nullptr, 1,
                          nullptr, 0 /* Core 0 */);

  Serial.println("[Setup] done – waiting for BLE connections");
}

void loop() {
  // All work happens in FreeRTOS tasks; keep the main loop asleep.
  vTaskDelay(portMAX_DELAY);
}