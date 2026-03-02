// ============================================================
//  ble_server.cpp  ·  NimBLE-Arduino v2.x GATT Server
//  JUFO-BIKE  ·  ESP32
//
//  Implements a BLE peripheral with:
//    Service 19B10000-…
//      DIST  char (READ | NOTIFY)  → push 4-byte distance payload
//      SPEED char (WRITE | WR_NR)  → receive 2-byte speed from app
//
//  Key NimBLE v2.x features used:
//    • onConnect  → updateConnParams()  (faster connection interval)
//    • onDisconnect → startAdvertising() (auto-reconnect)
//    • onSubscribe  → subscription state logging
//    • onStatus     → notify delivery result logging
//    • onWrite      → parse speed from app
//    • enableScanResponse(true) for broader Android compatibility
// ============================================================
#include "ble_server.h"

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <atomic>

// ── Internal state ────────────────────────────────────────────
static NimBLEServer *s_pServer = nullptr;
static NimBLECharacteristic *s_pDistChar = nullptr;

// Speed value written by the connected app (cm/s, atomic for ISR-safety)
static std::atomic<uint16_t> s_speedCms{BLE_SPEED_INVALID};

// ── Server callbacks ──────────────────────────────────────────
class ServerCB : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *pServer, NimBLEConnInfo &connInfo) override {
    Serial.printf("[BLE] Client connected: %s\n",
                  connInfo.getAddress().toString().c_str());
    /**
     * Request faster connection parameters right after connect:
     *   interval = 6–12 × 1.25 ms = 7.5–15 ms
     *   latency  = 0 (no skipped intervals)
     *   timeout  = 200 × 10 ms = 2 s
     * This reduces notify latency from the default ~45 ms to ~15 ms.
     */
    pServer->updateConnParams(connInfo.getConnHandle(), 6, 12, 0, 200);
  }

  void onDisconnect(NimBLEServer *, NimBLEConnInfo &connInfo,
                    int reason) override {
    Serial.printf(
        "[BLE] Client disconnected (reason %d) – restarting advertising\n",
        reason);
    // Reset speed so stale value isn't used after reconnect
    s_speedCms.store(BLE_SPEED_INVALID);
    NimBLEDevice::startAdvertising();
  }

  void onMTUChange(uint16_t mtu, NimBLEConnInfo &connInfo) override {
    Serial.printf("[BLE] MTU updated to %u for conn %u\n", mtu,
                  connInfo.getConnHandle());
  }
};

// ── DIST characteristic callbacks ─────────────────────────────
class DistCharCB : public NimBLECharacteristicCallbacks {
  void onSubscribe(NimBLECharacteristic *, NimBLEConnInfo &connInfo,
                   uint16_t subValue) override {
    const char *type = (subValue == 1)   ? "notifications"
                       : (subValue == 2) ? "indications"
                       : (subValue == 3) ? "notifications+indications"
                                         : "unsubscribed";
    Serial.printf("[BLE] DIST: client %u %s\n", connInfo.getConnHandle(), type);
  }

  void onStatus(NimBLECharacteristic *, int code) override {
    if (code != 0) {
      Serial.printf("[BLE] DIST notify error: %d (%s)\n", code,
                    NimBLEUtils::returnCodeToString(code));
    }
  }
};

// ── SPEED characteristic callbacks ───────────────────────────
class SpeedCharCB : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *pChar, NimBLEConnInfo &connInfo) override {
    NimBLEAttValue val = pChar->getValue();
    if (val.size() >= 2) {
      const uint16_t speed = (static_cast<uint16_t>(val[0]) << 8) | val[1];
      s_speedCms.store(speed);
      Serial.printf("[BLE] SPEED received: %u cm/s (%.1f km/h)\n", speed,
                    speed * 0.036f);
    } else {
      Serial.printf("[BLE] SPEED write: unexpected length %u\n",
                    static_cast<unsigned>(val.size()));
    }
  }
};

// Static callback instances (no dynamic allocation needed)
static ServerCB s_serverCB;
static DistCharCB s_distCB;
static SpeedCharCB s_speedCB;

// ── Public API ────────────────────────────────────────────────
void bleServerInit() {
  // 1. Initialise the NimBLE stack with the device name
  NimBLEDevice::init(BLE_DEVICE_NAME);

  // 2. Set TX power (+3 dBm is the highest safe value for ESP32)
  NimBLEDevice::setPower(3);

  // 3. Create server and register callbacks
  s_pServer = NimBLEDevice::createServer();
  s_pServer->setCallbacks(&s_serverCB);

  // 4. Create the GATT service
  NimBLEService *pSvc = s_pServer->createService(BLE_SERVICE_UUID);

  // 5. DIST characteristic: READ + NOTIFY, 4-byte payload
  s_pDistChar = pSvc->createCharacteristic(
      BLE_CHAR_DIST, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  s_pDistChar->setCallbacks(&s_distCB);
  // Set a safe initial value (both sensors faulted)
  const uint8_t initBuf[4] = {0xFF, 0xFF, 0xFF, 0xFF};
  s_pDistChar->setValue(initBuf, sizeof(initBuf));

  // 6. SPEED characteristic: WRITE (with response) + WRITE_NR (no response)
  //    The app can use either write type; we accept both.
  NimBLECharacteristic *pSpeedChar = pSvc->createCharacteristic(
      BLE_CHAR_SPEED, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  pSpeedChar->setCallbacks(&s_speedCB);

  // 7. Start the service (must be called before advertising starts)
  pSvc->start();

  // 8. Configure and start advertising
  NimBLEAdvertising *pAdv = NimBLEDevice::getAdvertising();
  pAdv->setName(BLE_DEVICE_NAME);         // local name in adv packet
  pAdv->addServiceUUID(BLE_SERVICE_UUID); // service UUID in adv packet
  /**
   * enableScanResponse(true): Android phones send an active scan request
   * after seeing the advertisement; the scan response carries the full name
   * and is required by some BLE apps (e.g. nRF Connect).
   */
  pAdv->enableScanResponse(true);
  pAdv->start();

  Serial.printf("[BLE] advertising as \"%s\"\n", BLE_DEVICE_NAME);
}

void bleNotifyDistances(uint16_t left, uint16_t rear) {
  if (!s_pDistChar)
    return;
  if (!s_pServer || s_pServer->getConnectedCount() == 0)
    return;

  const uint8_t buf[4] = {
      static_cast<uint8_t>(left >> 8), static_cast<uint8_t>(left & 0xFF),
      static_cast<uint8_t>(rear >> 8), static_cast<uint8_t>(rear & 0xFF)};
  s_pDistChar->setValue(buf, sizeof(buf));
  s_pDistChar->notify();
}

bool bleIsConnected() {
  return s_pServer && (s_pServer->getConnectedCount() > 0);
}

uint16_t bleGetSpeedCms() { return s_speedCms.load(); }
