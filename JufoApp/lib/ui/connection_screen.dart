import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ble_repository.dart';

class ConnectionScreen extends ConsumerWidget {
  const ConnectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the new BleState directly from the StateNotifierProvider
    final bleState = ref.watch(bleRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('BLE Connection')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              bleState.isConnected
                  ? Icons.bluetooth_connected
                  : bleState.isScanning
                  ? Icons.bluetooth_searching
                  : Icons.bluetooth,
              size: 100,
              color: bleState.isConnected
                  ? Colors.blue
                  : bleState.isScanning
                  ? Colors.blueAccent
                  : Colors.grey,
            ),
            const SizedBox(height: 32),
            Text(
              bleState.isConnected
                  ? 'Connected to JUFO-BIKE'
                  : bleState.isScanning
                  ? 'Scanning for JUFO-BIKE...'
                  : 'Not Connected',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            if (bleState.error != null) ...[
              const SizedBox(height: 12),
              Text(
                bleState.error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent, fontSize: 14),
              ),
            ],
            const SizedBox(height: 32),
            if (bleState.isScanning)
              const CircularProgressIndicator()
            else if (!bleState.isConnected)
              ElevatedButton.icon(
                onPressed: () =>
                    ref.read(bleRepositoryProvider.notifier).connect(),
                icon: const Icon(Icons.search),
                label: const Text('Scan & Connect'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 16,
                  ),
                  textStyle: const TextStyle(fontSize: 18),
                ),
              )
            else
              ElevatedButton.icon(
                onPressed: () =>
                    ref.read(bleRepositoryProvider.notifier).disconnect(),
                icon: const Icon(Icons.close),
                label: const Text('Disconnect'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 16,
                  ),
                  textStyle: const TextStyle(fontSize: 18),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
