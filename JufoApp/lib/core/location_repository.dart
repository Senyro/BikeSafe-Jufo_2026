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
  /// Current GPS speed in km/h.
  final double speedKmh;

  /// True = innerorts (Nominatim confirmed populated place).
  /// False = außerorts or not yet determined → conservative (außerorts).
  final bool isUrban;

  /// Whether a Nominatim result has been received at least once.
  final bool contextKnown;

  const LocationState({
    this.speedKmh = 0.0,
    this.isUrban = false,
    this.contextKnown = false,
  });

  LocationState copyWith({
    double? speedKmh,
    bool? isUrban,
    bool? contextKnown,
  }) => LocationState(
    speedKmh: speedKmh ?? this.speedKmh,
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
  final uri = Uri.parse(
    'https://nominatim.openstreetmap.org/reverse'
    '?lat=$lat&lon=$lon&format=json&zoom=14&addressdetails=1',
  );

  try {
    final response = await http
        .get(
          uri,
          headers: {
            // Nominatim policy: identify your app in User-Agent
            'User-Agent': 'JufoApp/1.0 (https://github.com/jufo)',
            'Accept-Language': 'de',
          },
        )
        .timeout(const Duration(seconds: 6));

    if (response.statusCode != 200) {
      developer.log(
        'Nominatim HTTP ${response.statusCode}',
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
    //   city        → Großstadt
    //   town        → Kleinstadt
    //   village     → Dorf
    //   suburb      → Stadtteil (innerhalb, zählt als innerorts)
    //   borough     → Bezirk
    // Absence of all these → typically außerorts (Feld, Wald, Autobahn, …)
    final bool urban =
        address.containsKey('city') ||
        address.containsKey('town') ||
        address.containsKey('village') ||
        address.containsKey('suburb') ||
        address.containsKey('borough');

    developer.log(
      'Nominatim: urban=$urban  addr=${address.keys.toList()}',
      name: 'LocationRepository',
    );
    return urban;
  } catch (e) {
    developer.log('Nominatim error: $e', name: 'LocationRepository');
    return null; // network unavailable – keep last known value
  }
}

// ── Repository ────────────────────────────────────────────────

class LocationRepository extends Notifier<LocationState> {
  // ── Geocoding cooldown ─────────────────────────────────────

  /// Minimum distance (m) between two Nominatim requests.
  static const double _kMinGeoDist = 200.0;

  Position? _lastGeoPos; // position of last successful geocoding
  bool _geoInFlight = false;

  // ── Subscriptions ──────────────────────────────────────────

  StreamSubscription<Position>? _posSub;

  // ── Riverpod Notifier ──────────────────────────────────────

  @override
  LocationState build() {
    ref.onDispose(() {
      _posSub?.cancel();
    });
    _startListening();
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
    // 1. Always update speed immediately
    final double kmh = pos.speed * 3.6;
    state = state.copyWith(speedKmh: kmh < 0 ? 0 : kmh);

    // 2. Trigger Nominatim if we've moved far enough
    _maybeGeocode(pos);
  }

  Future<void> _maybeGeocode(Position pos, {bool force = false}) async {
    if (_geoInFlight) return;

    // Only geocode if moved more than _kMinGeoDist since last request,
    // unless force=true (used on startup for the initial context lookup).
    if (!force && _lastGeoPos != null) {
      final double dist = Geolocator.distanceBetween(
        _lastGeoPos!.latitude,
        _lastGeoPos!.longitude,
        pos.latitude,
        pos.longitude,
      );
      if (dist < _kMinGeoDist) return;
    }

    _geoInFlight = true;
    final bool? urban = await _nominatimIsUrban(pos.latitude, pos.longitude);
    _geoInFlight = false;

    if (urban != null) {
      _lastGeoPos = pos;
      state = state.copyWith(isUrban: urban, contextKnown: true);
    }
  }

  // ── Public API ────────────────────────────────────────────

  /// Requests all needed runtime permissions.
  /// Also performs an immediate Nominatim lookup at the current position
  /// so that the urban/rural context is known before the user starts riding.
  Future<void> requestPermissions() async {
    await Permission.location.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();

    // Immediately determine urban/rural context for the current position.
    // This avoids the user having to move 200 m before contextKnown = true.
    _geocodeCurrentPosition();
  }

  /// Fetches the device's last/current GPS fix and geocodes it via Nominatim.
  void _geocodeCurrentPosition() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever)
        return;

      // Try the last known position first (instant, no GPS fix needed).
      // Fall back to getCurrentPosition if nothing is cached.
      Position? pos = await Geolocator.getLastKnownPosition();
      pos ??= await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.reduced, // faster fix for initial context
        ),
      );

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
