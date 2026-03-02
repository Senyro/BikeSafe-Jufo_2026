import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/debug_provider.dart';

class DebugScreen extends ConsumerWidget {
  const DebugScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final debugState = ref.watch(debugProvider);
    final notifier = ref.read(debugProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Simulation & Debug'),
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // ── Simulation toggle ───────────────────────────────
          SwitchListTile(
            title: const Text(
              'Simulationsmodus aktivieren',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            subtitle: const Text('Überschreibt GPS und BLE mit Werten unten'),
            value: debugState.isSimulationEnabled,
            activeColor: Colors.blueAccent,
            onChanged: (val) => notifier.toggleSimulation(val),
          ),
          const Divider(),

          // ── Urban / Rural context ───────────────────────────
          SwitchListTile(
            title: const Text(
              'Kontext: Innerorts',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            subtitle: Text(
              debugState.simulatedIsUrban
                  ? 'Innerorts → linker Alarm < 150 cm'
                  : 'Außerorts → linker Alarm < 200 cm',
            ),
            value: debugState.simulatedIsUrban,
            activeColor: Colors.orange,
            onChanged: debugState.isSimulationEnabled
                ? (val) => notifier.setUrban(val)
                : null,
          ),
          const Divider(),

          // ── Speed ───────────────────────────────────────────
          _buildSlider(
            title:
                'Simulierte Geschwindigkeit (${debugState.simulatedSpeedKmh.toStringAsFixed(1)} km/h)',
            subtitle:
                'Wird für Hinterabstand-Berechnung genutzt (2-Sekunden-Regel)',
            value: debugState.simulatedSpeedKmh,
            min: 0,
            max: 100,
            onChanged: debugState.isSimulationEnabled
                ? (val) => notifier.setSpeed(val)
                : null,
          ),

          // ── Left sensor ─────────────────────────────────────
          _buildSlider(
            title:
                'Linker Sensor (Überholen) – ${(debugState.simulatedLeftDistanceCm / 100).toStringAsFixed(2)} m',
            subtitle: debugState.simulatedIsUrban
                ? 'Schwellen: Alarm < 1,50 m  ·  Warnung < 2,00 m'
                : 'Schwellen: Alarm < 2,00 m  ·  Warnung < 2,50 m',
            value: debugState.simulatedLeftDistanceCm.toDouble(),
            min: 0,
            max: 500,
            onChanged: debugState.isSimulationEnabled
                ? (val) => notifier.setLeftDistance(val.toInt())
                : null,
          ),

          // ── Rear sensor ─────────────────────────────────────
          _buildSlider(
            title:
                'Hinterer Sensor (Folgeabstand) – ${(debugState.simulatedRearDistanceCm / 100).toStringAsFixed(2)} m',
            subtitle: 'Schwelle: Geschwindigkeit × 2 s (mind. 2 m)',
            value: debugState.simulatedRearDistanceCm.toDouble(),
            min: 0,
            max: 1000,
            onChanged: debugState.isSimulationEnabled
                ? (val) => notifier.setRearDistance(val.toInt())
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildSlider({
    required String title,
    required String subtitle,
    required double value,
    required double min,
    required double max,
    required void Function(double)? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            activeColor: Colors.blueAccent,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
