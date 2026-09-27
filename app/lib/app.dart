/// The application widget: theme, routing, and the global lifecycle hooks.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/di/providers.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'data/datasources/notification_datasource.dart';
import 'data/protocol/messages.dart';
import 'data/repositories/accident_repository.dart';
import 'data/repositories/device_repository.dart';
import 'features/alerts/alert_controller.dart';

/// The root widget.
class SaasApp extends ConsumerStatefulWidget {
  const SaasApp({super.key});

  @override
  ConsumerState<SaasApp> createState() => _SaasAppState();
}

class _SaasAppState extends ConsumerState<SaasApp> with WidgetsBindingObserver {
  final List<StreamSubscription<Object?>> _subs = <StreamSubscription<Object?>>[];
  StreamSubscription<NotificationResponse>? _responseSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Notifications, before anything can raise one.
    unawaited(_initNotifications());

    // The BLE event → alert handoff. Registered here, once, rather than in
    // each screen, so a crash is caught no matter which screen is showing.
    _subs.add(
      ref.read(deviceRepositoryProvider).messages.listen(_onDeviceMessage),
    );

  }

  Future<void> _initNotifications() async {
    final NotificationDatasource notifications =
        ref.read(notificationDatasourceProvider);
    await notifications.initialise();
    // Forward notification actions to the alert controller, so tapping "I'm
    // safe" on a lock screen does exactly what tapping the button in the app
    // would. A second path to the same behaviour that behaves differently is
    // how a user ends up unable to cancel a real alert.
    if (notifications case final LocalNotificationDatasource local) {
      local.onAction = (String action) => _onNotificationAction(action);
    }
  }

  void _onNotificationAction(String action) {
    final AlertController controller = ref.read(alertControllerProvider.notifier);
    switch (action) {
      case 'i_am_safe':
        unawaited(controller.dismiss());
      case 'send_help':
        unawaited(controller.sendHelp());
    }
  }

  /// Route a device event into the alert flow.
  void _onDeviceMessage(DeviceUpdate update) {
    final DeviceMessage message = update.message;
    if (message is! EventMessage) return;

    final AccidentRepository accidents = ref.read(accidentRepositoryProvider);
    // §8: the node retransmits until acknowledged, so the same event arrives
    // more than once. The repository's de-dup set is what stops that becoming
    // two alerts and two sets of dials.
    if (accidents.isDuplicate(eventId: message.eventId, type: message.eventType.wireName)) {
      return;
    }

    switch (message.eventType) {
      case EventType.accidentDetected:
        unawaited(
          ref.read(alertControllerProvider.notifier).begin(
                eventId: message.eventId,
                confirmWindowSec: message.confirmWindowSec ?? 10,
                impactG: message.impact?.magG,
                impactScore: message.score,
              ),
        );
      case EventType.manualSos:
        unawaited(
          ref.read(alertControllerProvider.notifier).begin(
                eventId: message.eventId,
                manualSos: true,
                confirmWindowSec: 0,
              ),
        );
      case EventType.alertCancelled:
      case EventType.alertConfirmed:
      case EventType.alertSent:
      case EventType.resolved:
      case EventType.deviceFault:
        break;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the foreground is the moment to drain the outbox and
    // re-check the link, because the phone has almost certainly been
    // disconnected and may now have coverage again.
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(accidentRepositoryProvider).syncOutbox());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final StreamSubscription<Object?> sub in _subs) {
      unawaited(sub.cancel());
    }
    unawaited(_responseSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Outbox drain on network return. `ref.listen` is only legal inside
    // `build` — Riverpod asserts on it anywhere else — so the subscription is
    // registered here rather than in `initState`, and Riverpod disposes it with
    // the widget. Reading the *provider* rather than its `AsyncValue` is what
    // makes this the idiomatic form.
    ref.listen<AsyncValue<bool>>(
      isOnlineProvider,
      (AsyncValue<bool>? _, AsyncValue<bool> next) {
        if (next.value ?? false) {
          unawaited(ref.read(accidentRepositoryProvider).syncOutbox());
        }
      },
    );

    final GoRouter router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'Smart Accident Alert',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      // Dark by default: the app is used in a car, at night, by someone who
      // should not be looking at a white screen.
      themeMode: ThemeMode.dark,
      builder: (BuildContext context, Widget? child) {
        // Clamp text scaling. The alert screen is a fixed-height layout with a
        // large countdown; an unbounded scale factor would overflow it at 2.0x.
        // Clamping to 1.4 keeps it legible for most users and correct for the
        // rest, which is the right trade for a safety-critical surface.
        final MediaQueryData media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: media.textScaler.clamp(minScaleFactor: 0.9, maxScaleFactor: 1.4),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
