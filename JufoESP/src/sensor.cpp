// ============================================================
//  sensor.cpp  ·  TFMini-S LiDAR reader (FreeRTOS task, Core 1)
//  JUFO-BIKE  ·  ESP32
//
//  Filtering strategy
//  ──────────────────
//  TFMini-S outputs ~100 Hz raw frames.  The task reads as fast as
//  possible and fills a circular buffer of MEDIAN_WIN raw samples per
//  sensor.  Every TASK_PERIOD_MS the guarded globals s_left / s_rear
//  are updated with the median of that window.
//
//  Why median instead of mean?
//    • TFMini-S emits MAX_DIST_CM (1200 cm) for objects below its
//      ~10 cm minimum range (hardware limitation – see note below).
//    • The median of an odd-size window eliminates single-sample
//      spikes completely, while a mean would just dilute them.
//    • A window of ~10 samples ≈ 200 ms at 50 Hz.  Fast enough to
//      capture a car overtaking (~0.5 s event at 100 km/h @2 m).
//
//  TFMini-S minimum-range note
//  ────────────────────────────
//  When the measured object is closer than ≈10 cm the sensor cannot
//  focus the IR spot and outputs MAX_DIST_CM (1200) or 0 instead of
//  the real distance.  We therefore treat both 0 and MAX_DIST_CM as
//  invalid samples (they are excluded from the median window and
//  replaced by DIST_FAULT when the whole window is invalid).
// ============================================================
#include "sensor.h"

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

// ── Constants ────────────────────────────────────────────────
static constexpr uint16_t MAX_DIST_CM = 1200u; // TFMini-S hardware max
static constexpr uint16_t MIN_DIST_CM = 10u;   // TFMini-S hardware min
static constexpr uint32_t SENSOR_TIMEOUT_MS =
    500u; // fault after 500 ms silence
static constexpr uint32_t TASK_PERIOD_MS =
    20u; // 50 Hz poll, ~10 samples/200 ms

// Median window: must be ODD for clean median, ≥ 5 to suppress outliers.
// 9 ≈ 180 ms latency at 50 Hz.
static constexpr uint8_t MEDIAN_WIN = 9u;

// ── Helper: compute median in-place (sorts a copy) ────────────
// Only considers values in [MIN_DIST_CM, MAX_DIST_CM - 1].
// Returns DIST_FAULT if fewer than (WIN/2)+1 valid samples exist.
static uint16_t medianOf(uint16_t *buf, uint8_t count) {
  // collect valid samples
  uint16_t valid[MEDIAN_WIN];
  uint8_t n = 0;
  for (uint8_t i = 0; i < count; i++) {
    const uint16_t v = buf[i];
    if (v >= MIN_DIST_CM && v < MAX_DIST_CM) {
      valid[n++] = v;
    }
  }
  // Need majority of window to be valid
  if (n < (MEDIAN_WIN / 2 + 1))
    return DIST_FAULT;
  // Insertion sort – tiny fixed array (≤ MEDIAN_WIN), no header needed
  for (uint8_t i = 1; i < n; i++) {
    const uint16_t key = valid[i];
    int8_t j = (int8_t)i - 1;
    while (j >= 0 && valid[j] > key) {
      valid[j + 1] = valid[j];
      j--;
    }
    valid[j + 1] = key;
  }
  return valid[n / 2];
}

// ── State (guarded by mutex) ──────────────────────────────────
static SemaphoreHandle_t s_mutex = nullptr;
static uint16_t s_left = DIST_FAULT;
static uint16_t s_rear = DIST_FAULT;

// ── TFMini-S frame parser ────────────────────────────────────
// Returns raw distance (cm) if a valid 9-byte frame is ready, else 0.
static uint16_t readTFMini(HardwareSerial &ser) {
  if (ser.available() < 9)
    return 0;

  if (ser.read() != 0x59)
    return 0;
  if (ser.read() != 0x59)
    return 0;

  const uint8_t dL = ser.read();
  const uint8_t dH = ser.read();
  const uint8_t sL = ser.read();
  const uint8_t sH = ser.read();
  const uint8_t tL = ser.read();
  const uint8_t tH = ser.read();
  const uint8_t chk = ser.read();

  if (((0x59u + 0x59u + dL + dH + sL + sH + tL + tH) & 0xFFu) != chk)
    return 0;

  return (static_cast<uint16_t>(dH) << 8) | dL;
  // Note: we do NOT cap here – DIST_FAULT / MAX_DIST_CM is handled in
  // the median filter so that out-of-range values are detected and excluded.
}

// ── Sensor task ───────────────────────────────────────────────
static void sensorTask(void *) {
  Serial1.begin(115200, SERIAL_8N1, SENSOR_LEFT_RX, SENSOR_LEFT_TX);
  Serial2.begin(115200, SERIAL_8N1, SENSOR_REAR_RX, SENSOR_REAR_TX);
  Serial.println("[Sensor] task running on core 1");

  // Circular buffers for median filter
  uint16_t leftBuf[MEDIAN_WIN] = {};
  uint16_t rearBuf[MEDIAN_WIN] = {};
  uint8_t leftIdx = 0, rearIdx = 0;
  uint8_t leftFill = 0, rearFill = 0; // how many slots filled

  uint32_t lastLeft = millis();
  uint32_t lastRear = millis();

  while (true) {
    const uint16_t rawLeft = readTFMini(Serial1);
    const uint16_t rawRear = readTFMini(Serial2);

    // Feed raw samples into the circular buffers (0 = no frame yet)
    if (rawLeft > 0) {
      leftBuf[leftIdx] = rawLeft;
      leftIdx = (leftIdx + 1) % MEDIAN_WIN;
      if (leftFill < MEDIAN_WIN)
        leftFill++;
      lastLeft = millis();
    }
    if (rawRear > 0) {
      rearBuf[rearIdx] = rawRear;
      rearIdx = (rearIdx + 1) % MEDIAN_WIN;
      if (rearFill < MEDIAN_WIN)
        rearFill++;
      lastRear = millis();
    }

    xSemaphoreTake(s_mutex, portMAX_DELAY);
    {
      const uint32_t now = millis();

      // Timeout check (sensor cable unplugged, etc.)
      if (now - lastLeft > SENSOR_TIMEOUT_MS) {
        s_left = DIST_FAULT;
      } else {
        s_left = medianOf(leftBuf, leftFill);
      }

      if (now - lastRear > SENSOR_TIMEOUT_MS) {
        s_rear = DIST_FAULT;
      } else {
        s_rear = medianOf(rearBuf, rearFill);
      }
    }
    xSemaphoreGive(s_mutex);

    vTaskDelay(pdMS_TO_TICKS(TASK_PERIOD_MS));
  }
}

// ── Public API ────────────────────────────────────────────────
void sensorTaskStart() {
  s_mutex = xSemaphoreCreateMutex();
  configASSERT(s_mutex != nullptr);

  xTaskCreatePinnedToCore(sensorTask, "Sensor", 4096, nullptr, 1, nullptr,
                          1 /* Core 1 */);
}

uint16_t sensorGetLeft() {
  xSemaphoreTake(s_mutex, portMAX_DELAY);
  const uint16_t v = s_left;
  xSemaphoreGive(s_mutex);
  return v;
}

uint16_t sensorGetRear() {
  xSemaphoreTake(s_mutex, portMAX_DELAY);
  const uint16_t v = s_rear;
  xSemaphoreGive(s_mutex);
  return v;
}
