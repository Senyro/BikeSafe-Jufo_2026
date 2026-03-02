import 'package:flutter_riverpod/flutter_riverpod.dart';

class DebugState {
  final bool isSimulationEnabled;
  final double simulatedSpeedKmh;
  final int simulatedLeftDistanceCm;
  final int simulatedRearDistanceCm;
  final bool simulatedIsUrban; // true = innerorts, false = außerorts

  DebugState({
    required this.isSimulationEnabled,
    required this.simulatedSpeedKmh,
    required this.simulatedLeftDistanceCm,
    required this.simulatedRearDistanceCm,
    required this.simulatedIsUrban,
  });

  DebugState copyWith({
    bool? isSimulationEnabled,
    double? simulatedSpeedKmh,
    int? simulatedLeftDistanceCm,
    int? simulatedRearDistanceCm,
    bool? simulatedIsUrban,
  }) {
    return DebugState(
      isSimulationEnabled: isSimulationEnabled ?? this.isSimulationEnabled,
      simulatedSpeedKmh: simulatedSpeedKmh ?? this.simulatedSpeedKmh,
      simulatedLeftDistanceCm:
          simulatedLeftDistanceCm ?? this.simulatedLeftDistanceCm,
      simulatedRearDistanceCm:
          simulatedRearDistanceCm ?? this.simulatedRearDistanceCm,
      simulatedIsUrban: simulatedIsUrban ?? this.simulatedIsUrban,
    );
  }
}

class DebugNotifier extends Notifier<DebugState> {
  @override
  DebugState build() {
    return DebugState(
      isSimulationEnabled: false,
      simulatedSpeedKmh: 45.0,
      simulatedLeftDistanceCm: 180,
      simulatedRearDistanceCm: 300,
      simulatedIsUrban: true, // default: innerorts im Simulationsmodus
    );
  }

  void toggleSimulation(bool value) {
    state = state.copyWith(isSimulationEnabled: value);
  }

  void setSpeed(double kmh) {
    state = state.copyWith(simulatedSpeedKmh: kmh);
  }

  void setLeftDistance(int cm) {
    state = state.copyWith(simulatedLeftDistanceCm: cm);
  }

  void setRearDistance(int cm) {
    state = state.copyWith(simulatedRearDistanceCm: cm);
  }

  void setUrban(bool urban) {
    state = state.copyWith(simulatedIsUrban: urban);
  }
}

final debugProvider = NotifierProvider<DebugNotifier, DebugState>(() {
  return DebugNotifier();
});
