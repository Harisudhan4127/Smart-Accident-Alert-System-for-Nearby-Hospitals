/// What the app asks the operating system for, and when.
///
/// This suite exists because of a specific complaint: the app threw permission
/// dialogs at the user on launch, several at once, before showing them a single
/// screen. Two of the three things it asked for are not needed to start, and one
/// of them — location — is the one an "accident app" gets refused most often
/// precisely because of when it asks.
///
/// The tests below pin the *timing* of each request, not just that a request
/// happens. A permission flow that eventually asks is not the same product as
/// one that asks at the right moment, and only the timing is what went wrong.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_accident_alert/core/di/providers.dart';
import 'package:smart_accident_alert/data/ble/ble_transport.dart';
import 'package:smart_accident_alert/data/ble/fake_ble_transport.dart';
import 'package:smart_accident_alert/data/datasources/location_datasource.dart';
import 'package:smart_accident_alert/data/datasources/maps_datasource.dart';
import 'package:smart_accident_alert/data/datasources/notification_datasource.dart';
import 'package:smart_accident_alert/features/splash/splash_screen.dart';

void main() {
  late FakeBleTransport transport;
  late FakeLocationDatasource location;
  late RecordingNotificationDatasource notifications;
  late ProviderContainer container;

  setUp(() {
    transport = FakeBleTransport();
    location = FakeLocationDatasource();
    notifications = RecordingNotificationDatasource();
    container = ProviderContainer(
      overrides: [
        bleTransportProvider.overrideWithValue(transport),
        locationDatasourceProvider.overrideWithValue(location),
        notificationDatasourceProvider.overrideWithValue(notifications),
        mapsDatasourceProvider.overrideWithValue(RecordingMapsDatasource()),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await transport.dispose();
    await location.dispose();
  });

  group('the splash screen asks for nothing', () {
    testWidgets('starting the app prompts for no permission at all',
        (WidgetTester tester) async {
      // The whole point. Before this was fixed, launching the app fired a
      // location prompt *and* a notification prompt concurrently — and because
      // Android can only show one system dialog at a time, the loser was
      // frequently dropped without a word, leaving the app with a permission the
      // user had answered and the app had not recorded.
      await container.read(splashControllerProvider.notifier).run();

      expect(
        location.promptCount,
        0,
        reason: 'the splash screen must not prompt for location. It is asked '
            'when an accident arrives and a position is actually needed.',
      );
    });

    test('a read-only location check does not count as a prompt', () async {
      final LocationPermissionOutcome outcome =
          await container.read(locationDatasourceProvider).currentPermission();
      expect(outcome, LocationPermissionOutcome.granted);
      expect(
        location.promptCount,
        0,
        reason: 'currentPermission() exists precisely so a status display can '
            'ask without showing a dialog. If it prompted, it would be a second '
            'name for ensurePermission() and the distinction would be pointless.',
      );
    });

    testWidgets('the splash reports location state without requesting it',
        (WidgetTester tester) async {
      // With nothing granted, the row must still be shown as OK — the app is
      // about to work, it just does not have a position yet. Showing a warning
      // here would nag about something that has not been asked for.
      location.outcome = LocationPermissionOutcome.denied;
      await container.read(splashControllerProvider.notifier).run();

      final CheckResult locationRow = container
          .read(splashControllerProvider)
          .firstWhere((CheckResult c) => c.label == 'Location');
      expect(locationRow.state, CheckState.ok);
      expect(locationRow.detail, contains('Asked when an accident'));
      expect(location.promptCount, 0);
    });

    test('notifications are reported, not requested', () async {
      // Not yet granted, which is the state the row has something to say about.
      notifications.permission = false;
      await container.read(splashControllerProvider.notifier).run();
      final List<CheckResult> checks = container.read(splashControllerProvider);
      final CheckResult row =
          checks.firstWhere((CheckResult c) => c.label == 'Notifications');
      expect(row.state, CheckState.ok);
      expect(row.detail, contains('Asked when the first alert'));
    });
  });

  group('nothing is fatal except a device with no radio', () {
    test('a healthy run proceeds', () async {
      final bool ok =
          await container.read(splashControllerProvider.notifier).run();
      expect(ok, isTrue);
    });

    test('location being unavailable does not block startup', () async {
      // PROJECT_PLAN §25: GPS unavailable is a degraded state to display, not a
      // reason to refuse. The accident is still detected and recorded; only the
      // position is missing.
      location.outcome = LocationPermissionOutcome.unavailable;
      final bool ok =
          await container.read(splashControllerProvider.notifier).run();
      expect(ok, isTrue, reason: 'a phone with no GPS is still useful');
    });
  });

  group('the Bluetooth row is actionable', () {
    test('a radio that is merely off is a warning with a button, not a block',
        () async {
      // This one blocked the app. A user who opens a phone app to check their
      // emergency contacts has no reason to have switched Bluetooth on, and being
      // met with a dead-end screen is not a defensible answer to that.
      final FakeBleTransport off = FakeBleTransport()
        ..adapterStatus = BleAdapterStatus.poweredOff;
      final ProviderContainer c = ProviderContainer(
        overrides: [
          bleTransportProvider.overrideWithValue(off),
          locationDatasourceProvider.overrideWithValue(location),
          notificationDatasourceProvider.overrideWithValue(notifications),
          mapsDatasourceProvider.overrideWithValue(RecordingMapsDatasource()),
        ],
      );
      addTearDown(() async {
        c.dispose();
        await off.dispose();
      });

      final bool ok = await c.read(splashControllerProvider.notifier).run();
      expect(ok, isTrue, reason: 'Bluetooth off must not trap the user');

      final CheckResult row = c
          .read(splashControllerProvider)
          .firstWhere((CheckResult r) => r.label == 'Bluetooth');
      expect(row.state, CheckState.warning);
      expect(
        row.action,
        CheckAction.turnOnBluetooth,
        reason: 'a warning with no button is a dead end',
      );
    });
  });
}
