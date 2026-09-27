/// Local and system notifications.
///
/// Two jobs, and the second is the one that actually matters:
///
/// 1. **The monitoring notification.** Android will kill a backgrounded app
///    that holds a BLE connection within a few minutes unless it is running a
///    foreground service. This notification is what that service is anchored
///    to — and therefore what keeps the accident detector alive during a drive.
/// 2. **The critical emergency notification.** With
///    `fullScreenIntent` + sound + vibration, this is the *only* thing that
///    wakes the screen when the app is backgrounded at the moment of a crash. If
///    it does not fire, the entire system fails silently, which is why it is
///    treated as the critical path and is called explicitly rather than being
///    buried in a helper.
library;

import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../core/logger.dart';
import '../../core/result.dart';
import '../../domain/entities/geo_point.dart';

/// Notification ids, so a repeated alert replaces rather than stacks.
abstract final class NotificationIds {
  /// The always-on monitoring notification.
  static const int monitoring = 1001;

  /// The emergency alert.
  static const int emergency = 1002;
}

/// Notification delivery.
abstract class NotificationDatasource {
  /// Create the channels. Idempotent.
  Future<Result<void>> initialise();

  /// Show the persistent "monitoring" notification.
  Future<Result<void>> showMonitoring({required String deviceName});

  /// Hide it (on disarm, or when the user wants the app quiet).
  Future<Result<void>> hideMonitoring();

  /// Fire the critical emergency alert.
  Future<Result<void>> showEmergencyAlert({
    required String title,
    required String body,
    required GeoPoint location,
    int countdownSec = 10,
  });

  /// Whether the OS would actually let us post notifications.
  Future<bool> hasPermission();

  /// Request the notification permission (Android 13+ `POST_NOTIFICATIONS`).
  Future<bool> requestPermission();
}

/// `flutter_local_notifications` implementation.
class LocalNotificationDatasource implements NotificationDatasource {
  LocalNotificationDatasource({AppLogger? log})
      : _log = log ?? AppLogger();

  final AppLogger _log;
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  /// `high` importance + a full-screen intent. The one that wakes the device.
  static const AndroidNotificationDetails _emergencyAndroid =
      AndroidNotificationDetails(
    'saas_emergency',
    'Emergency alerts',
    channelDescription: 'Possible-accident alerts. Bypasses Do Not Disturb.',
    importance: Importance.max,
    priority: Priority.max,
    // `alarm` is the category that matters: Android grants a full-screen intent
    // — and the right to bypass Do Not Disturb — only to ALARM or CALL
    // categories. Without it the alert would sit silently in the shade, which
    // for this app is the same as not firing at all.
    category: AndroidNotificationCategory.alarm,
    fullScreenIntent: true,
    channelBypassDnd: true,
    playSound: true,
    enableVibration: true,
    visibility: NotificationVisibility.public,
    actions: <AndroidNotificationAction>[
      AndroidNotificationAction('i_am_safe', 'I\'m safe', showsUserInterface: true),
      AndroidNotificationAction('send_help', 'Send help', showsUserInterface: true),
    ],
  );

  static const NotificationDetails _emergencyDetails =
      NotificationDetails(android: _emergencyAndroid);

  static const AndroidNotificationDetails _monitoringAndroid =
      AndroidNotificationDetails(
    'saas_monitoring',
    'Monitoring',
    channelDescription: 'Keeps accident monitoring active while driving.',
    importance: Importance.low,
    priority: Priority.low,
    ongoing: true,
    // Deliberately silent and invisible: this is a keep-alive, not an alert.
    playSound: false,
    enableVibration: false,
    onlyAlertOnce: true,
  );

  static const NotificationDetails _monitoringDetails =
      NotificationDetails(android: _monitoringAndroid);

  @override
  Future<Result<void>> initialise() {
    return guard<void>(
      () async {
        await _plugin.initialize(
          settings: const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          ),
          onDidReceiveNotificationResponse: _onResponse,
        );
      },
      kind: FailureKind.unknown,
      message: 'Could not set up notifications',
      log: _log,
      logTag: 'Notify',
    );
  }

  /// Notification action taps arrive here. Forwarded so the app can route them.
  void Function(String actionId)? onAction;

  void _onResponse(NotificationResponse response) {
    final String? action = response.actionId;
    if (action == null) return;
    _log.log(LogLevel.info, 'notify', 'action tapped: $action');
    onAction?.call(action);
  }

  @override
  Future<Result<void>> showMonitoring({required String deviceName}) {
    return guard<void>(
      () async {
        await _plugin.show(
          id: NotificationIds.monitoring,
          title: 'Monitoring active',
          body: '$deviceName is watching for impacts.',
          notificationDetails: _monitoringDetails,
        );
      },
      kind: FailureKind.unknown,
      message: 'Could not show the monitoring notification',
      log: _log,
      logTag: 'Notify',
    );
  }

  @override
  Future<Result<void>> hideMonitoring() {
    return guard<void>(
      () async => _plugin.cancel(id: NotificationIds.monitoring),
      kind: FailureKind.unknown,
      message: 'Could not hide the monitoring notification',
      log: _log,
      logTag: 'Notify',
    );
  }

  @override
  Future<Result<void>> showEmergencyAlert({
    required String title,
    required String body,
    required GeoPoint location,
    int countdownSec = 10,
  }) {
    return guard<void>(
      () async {
        await _plugin.show(
          id: NotificationIds.emergency,
          title: title,
          body: '$body\nAlerts in ${countdownSec}s — tap "I\'m safe" to cancel.',
          notificationDetails: _emergencyDetails,
          payload: '${location.latitude},${location.longitude}',
        );
        _log.log(LogLevel.info, 'notify', 'emergency alert posted');
      },
      kind: FailureKind.unknown,
      message: 'Could not post the emergency alert',
      log: _log,
      logTag: 'Notify',
    );
  }

  @override
  Future<bool> hasPermission() async {
    final AndroidFlutterLocalNotificationsPlugin? android =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    return await android?.areNotificationsEnabled() ?? true;
  }

  @override
  Future<bool> requestPermission() async {
    final AndroidFlutterLocalNotificationsPlugin? android =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    return await android?.requestNotificationsPermission() ?? true;
  }
}

/// Records notifications instead of showing them, for tests.
class RecordingNotificationDatasource implements NotificationDatasource {
  final List<String> shown = <String>[];
  int monitoringVisible = 0;
  bool permission = true;

  @override
  Future<Result<void>> initialise() async => const Ok<void>(null);

  @override
  Future<Result<void>> showMonitoring({required String deviceName}) async {
    monitoringVisible++;
    shown.add('monitoring:$deviceName');
    return const Ok<void>(null);
  }

  @override
  Future<Result<void>> hideMonitoring() async {
    if (monitoringVisible > 0) monitoringVisible--;
    return const Ok<void>(null);
  }

  @override
  Future<Result<void>> showEmergencyAlert({
    required String title,
    required String body,
    required GeoPoint location,
    int countdownSec = 10,
  }) async {
    shown.add('emergency:$title:$countdownSec');
    return const Ok<void>(null);
  }

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<bool> requestPermission() async {
    permission = true;
    return permission;
  }
}
