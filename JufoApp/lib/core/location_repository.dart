import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

// ── State ─────────────────────────────────────────────────────

/// Snapshot of the current location context.
class LocationState {
  /// Current GPS speed in m/s.
  final double currentSpeedMs;

  /// Latitude of the last position.
  final double latitude;

  /// Longitude of the last position.
  final double longitude;

  /// True = innerorts (Nominatim confirmed populated place).
  /// False = außerorts or not yet determined.
  final bool isUrban;

  /// Whether a Nominatim result has been received at least once.
  final bool contextKnown;

  const LocationState({
    this.currentSpeedMs = 0.0,
    this.latitude = 0.0,
    this.longitude = 0.0,
    this.isUrban = false,
    this.contextKnown = false,
  });

  /// Convenience: Current speed in km/h.
  double get speedKmh => currentSpeedMs * 3.6;

  LocationState copyWith({
    double? currentSpeedMs,
    double? latitude,
    double? longitude,
    bool? isUrban,
    bool? contextKnown,
  }) =>
      LocationState(
        currentSpeedMs: currentSpeedMs ?? this.currentSpeedMs,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        isUrban: isUrban ?? this.isUrban,
        contextKnown: contextKnown ?? this.contextKnown,
      );
}

// ── Nominatim helpers ─────────────────────────────────────────

/// Calls Nominatim reverse geocoding and returns true if the coordinate
/// is inside a populated place (innerorts).
///
/// OpenStreetMap's Nominatim is free and requires no API key.
/// Rate limit policy: 1 req/s.  We call it at most once per 200 m, so
/// the limit is never an issue during cycling.
Future<bool?> _nominatimIsUrban(double lat, double lon) async {
  // Round to 5 decimal places (~1.1m precision) to avoid unique requests for tiny movements.
  final roundedLat = double.parse(lat.toStringAsFixed(5));
  final roundedLon = double.parse(lon.toStringAsFixed(5));

  final uri = Uri.parse(
    'https://nominatim.openstreetmap.org/reverse'
    '?lat=$roundedLat&lon=$roundedLon&format=json&zoom=14&addressdetails=1'
    '&email=Tiki5@outlook.de', // Added email to reduce risk of blocking
  );

  try {
    final response = await http
        .get(
          uri,
          headers: {
            // Nominatim policy: unique User-Agent identifying the app.
            'User-Agent': 'Senyro-Jufo-Bike-Safety-App/1.1 (contact: Tiki5@outlook.de)',
            'Accept-Language': 'de',
          },
        )
        .timeout(const Duration(seconds: 4));

    if (response.statusCode != 200) {
      developer.log(
        'Nominatim HTTP ${response.statusCode}: ${response.body}',
        name: 'LocationRepository',
      );
      return null;
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>?;
    if (json == null) return null;

    final address = json['address'] as Map<String, dynamic>?;
    if (address == null) return null;

    // In Germany, OSM Nominatim returns one of these fields when inside
    // a recognised populated place (Ort / Ortschaft):
    final bool urban =
        address.containsKey('city') ||
        address.containsKey('town') ||
        address.containsKey('village') ||
        address.containsKey('suburb') ||
        address.containsKey('borough');

    developer.log(
      'Nominatim: urban=$urban address_keys=${address.keys.toList()}',
      name: 'LocationRepository',
    );
    return urban;
  } catch (e) {
    developer.log('Nominatim request failed: $e', name: 'LocationRepository');
    return null; // network unavailable or timeout
  }
}

// ── Repository ────────────────────────────────────────────────

class LocationRepository extends Notifier<LocationState> {
  // ── Geocoding cooldown ─────────────────────────────────────

  /// Minimum distance (m) between two Nominatim requests.
  static const double _kMinGeoDist = 200.0;

  Position? _lastGeoPos; // position of last successful geocoding
  DateTime? _lastRequestTime; // time of the last attempted request
  bool _geoInFlight = false;

  // For manual speed calculation fallback
  Position? _prevPos; // previous GPS position
  DateTime? _prevPosTime; // time of previous GPS position

  // ── Subscriptions ──────────────────────────────────────────

  StreamSubscription<Position>? _posSub;

  // ── Riverpod Notifier ──────────────────────────────────────

  @override
  LocationState build() {
    ref.onDispose(() {
      _posSub?.cancel();
    });
    // Stream is now started explicitly after permission check in requestPermissions()
    return const LocationState();
  }

  void _startListening() {
    _posSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 0,
          ),
        ).listen(
          _onPosition,
          onError: (e) => developer.log(
            'Position stream error: $e',
            name: 'LocationRepository',
          ),
        );
  }

  void _onPosition(Position pos) {
    // 1. Determine speed: prefer GPS-reported speed, fall back to manual calculation.
    double speedMs;
    final now = DateTime.now();

    if (pos.speed >= 0) {
      // GPS chip provides speed directly (ideal case).
      speedMs = pos.speed;
    } else if (_prevPos != null && _prevPosTime != null) {
      // Fallback: compute speed from consecutive position fixes.
      final double distM = Geolocator.distanceBetween(
        _prevPos!.latitude,
        _prevPos!.longitude,
        pos.latitude,
        pos.longitude,
      );
      final double elapsedS =
          now.difference(_prevPosTime!).inMilliseconds / 1000.0;
      speedMs = elapsedS > 0.1 ? distM / elapsedS : 0.0;
    } else {
      speedMs = 0.0;
    }

    _prevPos = pos;
    _prevPosTime = now;

    developer.log(
      'Speed: ${(speedMs * 3.6).toStringAsFixed(1)} km/h '
      '(GPS raw: ${pos.speed.toStringAsFixed(2)} m/s)',
      name: 'LocationRepository',
    );

    state = state.copyWith(
      currentSpeedMs: speedMs,
      latitude: pos.latitude,
      longitude: pos.longitude,
    );

    // 2. Trigger Nominatim if we've moved far enough
    _maybeGeocode(pos);
  }

  Future<void> _maybeGeocode(Position pos, {bool force = false}) async {
    if (_geoInFlight) return;

    // 1. Nominatim rate-limit: Max 1 request per second (we allow 1.1s for safety).
    // This applies even if 'force' is true, to protect the server.
    if (_lastRequestTime != null) {
      final elapsedMs =
          DateTime.now().difference(_lastRequestTime!).inMilliseconds;
      if (elapsedMs < 1100) return;
    }

    // 2. Only geocode if moved more than _kMinGeoDist since last request,
    // unless force=true (used on startup for the initial context lookup).
    // If the context is still unknown, we ignore the distance check to retry faster (but still rate-limited).
    if (!force && _lastGeoPos != null && state.contextKnown) {
      final double dist = Geolocator.distanceBetween(
        _lastGeoPos!.latitude,
        _lastGeoPos!.longitude,
        pos.latitude,
        pos.longitude,
      );
      if (dist < _kMinGeoDist) return;
    }

    _geoInFlight = true;
    _lastRequestTime = DateTime.now();
    try {
      final bool? urban = await _nominatimIsUrban(pos.latitude, pos.longitude);
      if (urban != null) {
        _lastGeoPos = pos;
        state = state.copyWith(isUrban: urban, contextKnown: true);
      }
    } finally {
      // Ensure flag is always reset, even on network error or timeout.
      _geoInFlight = false;
    }
  }

  /// Requests all needed runtime permissions.
  /// Also starts the location stream and performs an immediate Nominatim lookup
  /// at the current position so that the urban/rural context is known.
  Future<bool> requestPermissions() async {
    final locStatus = await Permission.location.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();

    if (locStatus.isGranted || locStatus.isLimited) {
      // Start the stream now that we have permission
      _startListening();
      // Immediately determine urban/rural context for the current position.
      _geocodeCurrentPosition();
      return true;
    }
    
    developer.log('Location permission not granted: $locStatus', name: 'LocationRepository');
    return false;
  }

  /// Fetches the device's last/current GPS fix and geocodes it via Nominatim.
  void _geocodeCurrentPosition() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      // Try the last known position first (instant, no GPS fix needed).
      // Fall back to getCurrentPosition if nothing is cached.
      Position? pos = await Geolocator.getLastKnownPosition();
      pos ??= await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low, // More reliable fix than 'reduced' for initial context
        ),
      ).timeout(const Duration(seconds: 15)); // Prevent hanging on startup if indoors

      developer.log(
        'Initial geocode at ${pos.latitude}, ${pos.longitude}',
        name: 'LocationRepository',
      );
      await _maybeGeocode(pos, force: true);
    } catch (e) {
      developer.log('Initial geocode error: $e', name: 'LocationRepository');
    }
  }
}

// ── Providers ─────────────────────────────────────────────────

final locationRepositoryProvider =
    NotifierProvider<LocationRepository, LocationState>(LocationRepository.new);

/// Convenience: just the speed in km/h (used by distance_evaluator).
final speedStreamProvider = StreamProvider<double>((ref) async* {
  // Watch the notifier and re-emit speed on every state change
  await for (final _ in Stream.periodic(const Duration(milliseconds: 500))) {
    yield ref.read(locationRepositoryProvider).speedKmh;
  }
});

/// Convenience: permission request forwarded from the notifier.
extension LocationRepositoryExt on LocationRepository {
  static LocationRepository of(Ref ref) =>
      ref.read(locationRepositoryProvider.notifier);
}
