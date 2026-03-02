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

  // ── Disconnected shortcut ──────────────────────────────────
  if (!isConnected) {
    return EvaluationResult(
      isConnected: false,
      currentSpeedKmh: 0.0,
      leftDistanceCm: 0xFFFF,
      rearDistanceCm: 0xFFFF,
      leftState: SafetyState.fault,
      rearState: SafetyState.fault,
      locationContext: 'Unbekannt',
      contextKnown: false,
    );
  }

  // ── Context label ──────────────────────────────────────────
  final String context = isUrban ? 'Innerorts' : 'Außerorts';

  // ── Left sensor – overtaking (StVO §5 Abs. 4) ─────────────
  // Innerorts: 1.5 m Mindestabstand → Alarm < 150 cm
  // Außerorts: 2.0 m Mindestabstand → Alarm < 200 cm
  SafetyState leftState;
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

  // ── Rear sensor – following distance (2-second rule) ──────
  // Dynamic threshold: speed × 2 s, minimum 2 m
  SafetyState rearState;
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

  return EvaluationResult(
    isConnected: true,
    currentSpeedKmh: speedKmh,
    leftDistanceCm: leftDist,
    rearDistanceCm: rearDist,
    leftState: leftState,
    rearState: rearState,
    locationContext: context,
    contextKnown: contextKnown,
  );
});
