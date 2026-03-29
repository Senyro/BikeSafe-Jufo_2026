import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ble_repository.dart';
import '../core/location_repository.dart';
import '../core/distance_evaluator.dart';
import 'debug_screen.dart';
import 'connection_screen.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initApp();
    });
  }

  Future<void> _initApp() async {
    await ref.read(locationRepositoryProvider.notifier).requestPermissions();
    await ref.read(bleRepositoryProvider.notifier).connect();
  }

  Color _getColorForState(SafetyState state) {
    switch (state) {
      case SafetyState.safe:
        return Colors.green;
      case SafetyState.warning:
        return Colors.orange;
      case SafetyState.alarm:
        return Colors.redAccent;
      case SafetyState.fault:
        return Colors.grey;
    }
  }

  Widget _buildSensorZone(String title, int distanceCm, SafetyState state) {
    Color zoneColor = _getColorForState(state);
    bool isAlarm = state == SafetyState.alarm;

    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        margin: const EdgeInsets.all(8.0),
        decoration: BoxDecoration(
          color: zoneColor.withValues(alpha: isAlarm ? 0.3 : 0.05),
          border: Border.all(color: zoneColor, width: isAlarm ? 4.0 : 2.0),
          borderRadius: BorderRadius.circular(24.0),
          boxShadow: isAlarm
              ? [
                  BoxShadow(
                    color: zoneColor.withValues(alpha: 0.5),
                    blurRadius: 20,
                    spreadRadius: 5,
                  ),
                ]
              : [],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              distanceCm == 0xFFFF
                  ? "--"
                  : "${(distanceCm / 100).toStringAsFixed(1)}m",
              style: TextStyle(
                fontSize: 72,
                fontWeight: FontWeight.w900,
                color: zoneColor,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              state.name.toUpperCase(),
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: zoneColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final evalResult = ref.watch(evaluationProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'JUFO Bike Safety',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report, color: Colors.white54),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (c) => const DebugScreen()),
              );
            },
          ),
          IconButton(
            icon: Icon(
              evalResult.isConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
              color: evalResult.isConnected ? Colors.blue : Colors.red,
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (c) => const ConnectionScreen()),
              );
            },
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 24.0,
                vertical: 12.0,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "SPEED",
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize: 14,
                          letterSpacing: 1.5,
                        ),
                      ),
                      Text(
                        "${evalResult.currentSpeedKmh.toStringAsFixed(1)} km/h",
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text(
                        "CONTEXT",
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize: 14,
                          letterSpacing: 1.5,
                        ),
                      ),
                      Text(
                        evalResult.locationContext,
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0),
              child: Divider(color: Colors.white24, thickness: 1),
            ),
            _buildSensorZone(
              "LEFT (Overtaking)",
              evalResult.leftDistanceCm,
              evalResult.leftState,
            ),
            _buildSensorZone(
              "REAR (Following)",
              evalResult.rearDistanceCm,
              evalResult.rearState,
            ),
          ],
        ),
      ),
    );
  }
}
