/// BLE pairing (PROJECT_PLAN §12 flow, §13).
///
/// Scanning is filtered to the app's own service UUID (§2.4), so this list
/// contains only nodes that speak the protocol — not the dozens of unrelated
/// BLE devices a phone sees in a car park. The result is a one-tap pairing
/// experience.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/spacing.dart';
import '../../data/ble/ble_transport.dart';
import '../../widgets/ui_kit.dart';
import 'pairing_state.dart';

/// The pairing screen.
class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key});

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  @override
  Widget build(BuildContext context) {
    final PairingViewState state = ref.watch(pairingViewProvider);
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Pair a node')),
      body: Column(
        children: <Widget>[
          if (state.error != null)
            NoticeBanner(message: state.error!, severity: StatusSeverity.warning),
          Expanded(
            child: state.connecting
                ? const Center(
                    child: SizedBox(
                      width: 30,
                      height: 30,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                : state.found.isEmpty
                    ? _searching(context)
                    : ListView.separated(
                        padding: const EdgeInsets.all(Spacing.medium),
                        itemCount: state.found.length,
                        separatorBuilder: (_, __) => const SizedBox(height: Spacing.xs),
                        itemBuilder: (BuildContext context, int index) {
                          final BlePeripheralInfo info = state.found[index];
                          return GlassCard(
                            onTap: () => _connect(info),
                            child: Row(
                              children: <Widget>[
                                const Icon(Icons.sensors, color: AppColors.electric),
                                const SizedBox(width: Spacing.sm),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        info.displayName,
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(fontWeight: FontWeight.w700),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        info.id,
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: theme.colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                StatusPill(
                                  label: info.signalLabel,
                                  severity: info.rssi > -67
                                      ? StatusSeverity.good
                                      : StatusSeverity.warning,
                                  icon: Icons.network_cell,
                                  dense: true,
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _searching(BuildContext context) {
    return EmptyState(
      icon: Icons.bluetooth_searching,
      title: 'Looking for nodes…',
      message: 'Make sure the node is powered and its LED is blinking. '
          'It should appear within a few seconds.',
    );
  }

  Future<void> _connect(BlePeripheralInfo info) async {
    final bool ok = await ref.read(pairingViewProvider.notifier).connect(info);
    if (!mounted) return;
    if (ok) {
      context.goNamed(AppRoutes.home);
    }
  }
}
