import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ble_repository.dart';
import 'location_repository.dart';
import 'debug_provider.dart';

enum SafetyState { safe, warning, alarm, fault }

class EvaluationResult {
  final bool isConnected;
  final double currentSpeedKmh;
  final int leftDistanceCm;
  final int rearDistanceCm;
  final SafetyState leftState;
  final SafetyState rearState;
  final String locationContext; // "Innerorts" or "Außerorts"
  final bool contextKnown; // false = Nominatim hasn't responded yet

  EvaluationResult({
    required this.isConnected,
    required this.currentSpeedKmh,
    required this.leftDistanceCm,
    required this.rearDistanceCm,
    required this.leftState,
    required this.rearState,
    required this.locationContext,
    required this.contextKnown,
  });
}

final evaluationProvider = Provider<EvaluationResult>((ref) {
  final debugState = ref.watch(debugProvider);
  final bool isSimulation = debugState.isSimulationEnabled;

  // ── Data sources ───────────────────────────────────────────
  final int leftDist;
  final int rearDist;
  final bool isConnected;
  final double speedKmh;
  final bool isUrban;
  final bool contextKnown;

  if (isSimulation) {
    leftDist = debugState.simulatedLeftDistanceCm;
    rearDist = debugState.simulatedRearDistanceCm;
    isConnected = true;
    speedKmh = debugState.simulatedSpeedKmh;
    isUrban = debugState.simulatedIsUrban;
    contextKnown = true;
  } else {
    final bleState = ref.watch(bleRepositoryProvider);
    final locState = ref.watch(locationRepositoryProvider);
    leftDist = bleState.distLeftCm;
    rearDist = bleState.distRearCm;
    isConnected = bleState.isConnected;
    speedKmh = locState.speedKmh;
    isUrban = locState.isUrban;
    contextKnown = locState.contextKnown;
  }

  // ── Context label ──────────────────────────────────────────
  final String context = contextKnown
      ? (isUrban ? 'Innerorts' : 'Außerorts')
      : 'Bestimme...';

  // ── Sensor safety handling ──────────────────────────────────
  SafetyState leftState;
  SafetyState rearState;
  int leftDistResult;
  int rearDistResult;

  if (!isConnected) {
    // If bike is disconnected, show sensor failure/unknown
    leftState = SafetyState.fault;
    rearState = SafetyState.fault;
    leftDistResult = 0xFFFF;
    rearDistResult = 0xFFFF;
  } else if (speedKmh <= 2.0) {
    // If stationary or moving very slowly (<= 2 km/h), suppress all warnings
    leftState = SafetyState.safe;
    rearState = SafetyState.safe;
    leftDistResult = leftDist;
    rearDistResult = rearDist;
  } else {
    // ── Connected Logic ──────────────────────────────────────

    // Left sensor – overtaking (StVO §5 Abs. 4)
    if (leftDist == 0xFFFF) {
      leftState = SafetyState.fault;
    } else {
      final int alarm = isUrban ? 150 : 200; // cm
      final int warning = alarm + 50; // +0.5 m Puffer
      if (leftDist < alarm) {
        leftState = SafetyState.alarm;
      } else if (leftDist < warning) {
        leftState = SafetyState.warning;
      } else {
        leftState = SafetyState.safe;
      }
    }
    leftDistResult = leftDist;

    // Rear sensor – following distance (2-second rule)
    if (rearDist == 0xFFFF) {
      rearState = SafetyState.fault;
    } else {
      final double speedMs = speedKmh / 3.6;
      final double requiredM = (speedMs * 2.0).clamp(2.0, double.infinity);
      final int alarm = (requiredM * 100).toInt();
      final int warning = alarm + 200; // +2 m Puffer

      if (rearDist < alarm) {
        rearState = SafetyState.alarm;
      } else if (rearDist < warning) {
        rearState = SafetyState.warning;
      } else {
        rearState = SafetyState.safe;
      }
    }
    rearDistResult = rearDist;
  }

  return EvaluationResult(
    isConnected: isConnected,
    currentSpeedKmh: speedKmh,
    leftDistanceCm: leftDistResult,
    rearDistanceCm: rearDistResult,
    leftState: leftState,
    rearState: rearState,
    locationContext: context,
    contextKnown: contextKnown,
  );
});
