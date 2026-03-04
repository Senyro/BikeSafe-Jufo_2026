import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ── Data model ────────────────────────────────────────────────

/// Immutable snapshot of the BLE connection + sensor readings.
class BleState {
  final bool isConnected;
  final bool isScanning;
  final int distLeftCm; // 0xFFFF = sensor fault / no data
  final int distRearCm; // 0xFFFF = sensor fault / no data
  final String? error; // non-null when a recoverable error occurred

  const BleState({
    this.isConnected = false,
    this.isScanning = false,
    this.distLeftCm = 0xFFFF,
    this.distRearCm = 0xFFFF,
    this.error,
  });

  BleState copyWith({
    bool? isConnected,
    bool? isScanning,
    int? distLeftCm,
    int? distRearCm,
    String? error,
    bool clearError = false,
  }) {
    return BleState(
      isConnected: isConnected ?? this.isConnected,
      isScanning: isScanning ?? this.isScanning,
      distLeftCm: distLeftCm ?? this.distLeftCm,
      distRearCm: distRearCm ?? this.distRearCm,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  String toString() =>
      'BleState(connected=$isConnected, scanning=$isScanning, '
      'left=$distLeftCm cm, rear=$distRearCm cm)';
}

// ── BLE UUIDs (must match ESP32 ble_server.h) ─────────────────
const String _kServiceUuid = '19b10000-e8f2-537e-4f6c-d104768a1214';
const String _kDistUuid = '19b10001-e8f2-537e-4f6c-d104768a1214';
const String _kSpeedUuid = '19b10002-e8f2-537e-4f6c-d104768a1214';
const String _kWarnUuid = '19b10003-e8f2-537e-4f6c-d104768a1214';
const String _kDeviceName = 'JUFO-BIKE';

// ── Auto-reconnect delay ──────────────────────────────────────
const Duration _kReconnectDelay = Duration(seconds: 3);

// ── BLE Repository ────────────────────────────────────────────
/// Manages the full BLE lifecycle:
///   scan → connect → subscribe → notify → [disconnect → reconnect]
///
/// Call [connect] once (e.g. from initState / a button).
/// Call [sendSpeed] periodically from the location repository.
class BleRepository extends Notifier<BleState> {
  // ── Private internals ─────────────────────────────────────

  BluetoothDevice? _device;
  BluetoothCharacteristic? _speedChar;
  BluetoothCharacteristic? _warnChar; // debug sim: send W-code to ESP32

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connStateSub;
  StreamSubscription<List<int>>? _notifySub;

  bool _reconnecting = false;

  @override
  BleState build() {
    // Register a disposal callback so all subs are cleaned up
    ref.onDispose(_cleanup);
    return const BleState();
  }

  // ── Public API ────────────────────────────────────────────

  /// Starts a BLE scan and connects to JUFO-BIKE when found.
  Future<void> connect() async {
    if (state.isScanning || state.isConnected) return;

    try {
      final supported = await FlutterBluePlus.isSupported;
      if (!supported) {
        _setError('Bluetooth not supported on this device');
        return;
      }

      state = state.copyWith(isScanning: true, clearError: true);
      _log('Starting BLE scan for "$_kDeviceName" (service UUID filter)');

      // Subscribe BEFORE starting scan to avoid missing early results
      await _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen(
        _onScanResult,
        onError: (e) => _setError('Scan error: $e'),
      );

      // Filter by service UUID — more reliable than withNames on Android
      // because Android often doesn't include the device name in advertising
      // packets until after a connection or full discovery.
      await FlutterBluePlus.startScan(
        withServices: [Guid(_kServiceUuid)],
        timeout: const Duration(seconds: 20),
        androidUsesFineLocation: false,
      );

      // If scan ended without finding the device, update state
      if (state.isScanning) {
        state = state.copyWith(isScanning: false);
        _log('Scan finished – device not found, scheduling retry');
        _scheduleReconnect();
      }
    } catch (e) {
      state = state.copyWith(isScanning: false);
      _setError('connect() error: $e');
    }
  }

  /// Gracefully disconnect and stop any pending reconnect.
  Future<void> disconnect() async {
    _reconnecting = false;
    await _cancelSubscriptions();
    await _device?.disconnect();
    _device = null;
    _speedChar = null;
    _warnChar = null;
    state = const BleState();
    _log('Disconnected by user');
  }

  /// Write the current GPS speed (m/s) to the SPEED characteristic.
  /// Converts to cm/s and sends as 2 big-endian bytes.
  /// Silently no-ops when not connected.
  Future<void> sendSpeed(double speedMs) async {
    if (_speedChar == null || !state.isConnected) return;

    final int cms = (speedMs * 100).round().clamp(0, 0xFFFE);
    final List<int> bytes = [(cms >> 8) & 0xFF, cms & 0xFF];
    try {
      await _speedChar!.write(bytes, withoutResponse: true);
    } catch (e) {
      _log('sendSpeed error: $e');
    }
  }

  /// Write a W-code (0/1/2) to the WARN characteristic.
  /// Used by the debug simulation screen to force-display a warning on the Pi.
  /// Silently no-ops when not connected or WARN char not found.
  Future<void> sendMatrixCode(int code) async {
    if (_warnChar == null || !state.isConnected) return;
    try {
      await _warnChar!.write([code & 0xFF], withoutResponse: true);
      _log('sendMatrixCode: W$code sent');
    } catch (e) {
      _log('sendMatrixCode error: $e');
    }
  }

  // ── Private helpers ───────────────────────────────────────

  void _onScanResult(List<ScanResult> results) async {
    for (final r in results) {
      final name = r.device.platformName;
      // When scanning with service UUID filter, any result is our device.
      // Name may be empty on Android until after connection.
      final isTarget = name == _kDeviceName || name.isEmpty;
      if (!isTarget) continue;

      _log('Found target device (name="$name") – stopping scan');
      await FlutterBluePlus.stopScan();
      await _scanSub?.cancel();
      _scanSub = null;
      state = state.copyWith(isScanning: false);
      _device = r.device;
      await _connectToDevice();
      break;
    }
  }

  Future<void> _connectToDevice() async {
    if (_device == null) return;

    try {
      _log('Connecting to ${_device!.remoteId}');
      await _device!.connect(
        timeout: const Duration(seconds: 10),
        // flutter_blue_plus v2 requires a licence declaration
        // ignore: deprecated_member_use
        license: License.free,
      );

      state = state.copyWith(
        isConnected: true,
        isScanning: false,
        distLeftCm: 0xFFFF,
        distRearCm: 0xFFFF,
        clearError: true,
      );
      _log('Connected');

      await _connStateSub?.cancel();
      _connStateSub = _device!.connectionState.listen(
        _onConnectionStateChange,
        onError: (e) => _log('ConnectionState stream error: $e'),
      );

      await _subscribeToCharacteristics();
    } catch (e) {
      _log('_connectToDevice error: $e');
      state = state.copyWith(isConnected: false, isScanning: false);
      _setError('Connection failed: $e');
      _scheduleReconnect();
    }
  }

  void _onConnectionStateChange(BluetoothConnectionState s) {
    _log('Connection state → $s');
    if (s == BluetoothConnectionState.disconnected) {
      state = state.copyWith(
        isConnected: false,
        distLeftCm: 0xFFFF,
        distRearCm: 0xFFFF,
      );
      _notifySub?.cancel();
      _notifySub = null;
      _speedChar = null;
      _scheduleReconnect();
    }
  }

  Future<void> _subscribeToCharacteristics() async {
    if (_device == null) return;

    try {
      final services = await _device!.discoverServices();

      for (final svc in services) {
        if (svc.uuid.toString().toLowerCase() != _kServiceUuid) continue;
        _log('JUFO service found');

        for (final chr in svc.characteristics) {
          final uuid = chr.uuid.toString().toLowerCase();

          if (uuid == _kDistUuid && chr.properties.notify) {
            await chr.setNotifyValue(true);
            await _notifySub?.cancel();
            _notifySub = chr.onValueReceived.listen(
              _onDistNotification,
              onError: (e) => _log('DIST notify stream error: $e'),
            );
            _log('Subscribed to DIST notifications');
          }

          if (uuid == _kSpeedUuid) {
            _speedChar = chr;
            _log('SPEED characteristic found');
          }

          if (uuid == _kWarnUuid) {
            _warnChar = chr;
            _log('WARN characteristic found');
          }
        }
        break; // found our service, no need to continue
      }
    } catch (e) {
      _log('_subscribeToCharacteristics error: $e');
      _setError('Service discovery failed: $e');
    }
  }

  void _onDistNotification(List<int> value) {
    if (value.length < 4) {
      _log('DIST: unexpected length ${value.length}');
      return;
    }
    final int left = (value[0] << 8) | value[1];
    final int rear = (value[2] << 8) | value[3];
    state = state.copyWith(distLeftCm: left, distRearCm: rear);
  }

  void _scheduleReconnect() {
    if (_reconnecting) return;
    _reconnecting = true;
    _log('Auto-reconnect in ${_kReconnectDelay.inSeconds} s');
    Future.delayed(_kReconnectDelay, () {
      _reconnecting = false;
      if (!state.isConnected) connect();
    });
  }

  Future<void> _cancelSubscriptions() async {
    await _scanSub?.cancel();
    _scanSub = null;
    await _notifySub?.cancel();
    _notifySub = null;
    await _connStateSub?.cancel();
    _connStateSub = null;
  }

  void _cleanup() {
    _cancelSubscriptions();
    _device?.disconnect();
  }

  void _setError(String msg) {
    _log('ERROR: $msg');
    state = state.copyWith(error: msg);
  }

  void _log(String msg) => developer.log(msg, name: 'BleRepository');
}

// ── Riverpod providers ────────────────────────────────────────

/// Main provider: exposes [BleState] and gives access to
/// [BleRepository] methods via `.notifier`.
final bleRepositoryProvider = NotifierProvider<BleRepository, BleState>(
  BleRepository.new,
);

/// Convenience provider: just the [BleState] snapshot.
final bleStateProvider = Provider<BleState>((ref) {
  return ref.watch(bleRepositoryProvider);
});
