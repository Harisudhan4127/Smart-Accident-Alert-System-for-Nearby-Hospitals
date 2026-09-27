/// Smoke tests for the application widget.
///
/// `flutter create` generated a default counter test here. That test cannot
/// survive any real change to the app — it asserts a `MyApp` that does not
/// exist — so it has been replaced with tests of the root widget.
///
/// These tests are also the justification for the `BleTransport` abstraction:
/// `flutter_blue_plus` throws `UnsupportedError` on the test platform, so the
/// only way to build the real app widget in a widget test is to inject the
/// in-memory node. That is a direct, practical payoff for keeping every plugin
/// behind an interface.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_accident_alert/app.dart';
import 'package:smart_accident_alert/core/di/providers.dart';
import 'package:smart_accident_alert/data/ble/fake_ble_transport.dart';
import 'package:smart_accident_alert/data/datasources/location_datasource.dart';
import 'package:smart_accident_alert/data/datasources/maps_datasource.dart';
import 'package:smart_accident_alert/data/datasources/notification_datasource.dart';

void main() {
  late FakeBleTransport transport;
  late FakeLocationDatasource location;
  late RecordingNotificationDatasource notifications;

  setUp(() {
    transport = FakeBleTransport();
    location = FakeLocationDatasource();
    notifications = RecordingNotificationDatasource();
  });

  tearDown(() async {
    await transport.dispose();
    await location.dispose();
  });

  Widget harness() => ProviderScope(
        overrides: [
          // The real transport, real GPS and real notifications all reach
          // platform channels that do not exist under `flutter test`.
          bleTransportProvider.overrideWithValue(transport),
          locationDatasourceProvider.overrideWithValue(location),
          notificationDatasourceProvider.overrideWithValue(
            notifications,
          ),
          mapsDatasourceProvider.overrideWithValue(RecordingMapsDatasource()),
        ],
        child: const SaasApp(),
      );

  testWidgets('builds without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens on the splash screen, not the dashboard',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    // The wordmark is the splash's identifying content. Asserting on it avoids
    // a test coupled to the router's exact widget tree.
    expect(find.text('SMART ACCIDENT'), findsWidgets);
    expect(find.text('ALERT SYSTEM'), findsOneWidget);
  });

  testWidgets('is hosted by a MaterialApp, so Material widgets resolve',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    expect(
      find.byType(MaterialApp),
      findsOneWidget,
      reason: 'the router is hosted by a MaterialApp, which every Material '
          'widget in the tree depends on',
    );
  });

  testWidgets('runs dark by default, because it is used at night in a car',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    final MaterialApp app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);

    // The resolved brightness has to be read from *below* the MaterialApp: the
    // app element itself is above the Theme it installs, so `Theme.of` there
    // reports the ambient default rather than the app's choice.
    final Finder content = find.text('SMART ACCIDENT');
    expect(content, findsWidgets);
    expect(
      Theme.of(tester.element(content.first)).brightness,
      Brightness.dark,
    );
  });
}
