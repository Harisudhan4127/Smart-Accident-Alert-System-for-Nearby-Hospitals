/// Application entry point.
///
/// The one non-obvious decision here is that **Firebase initialisation failure
/// is non-fatal**. A safety app that refuses to start because a cloud project
/// is misconfigured would be worse than one that runs entirely offline: §25
/// requires the app to keep working without a network, and a missing
/// `google-services.json` is just a permanent network outage from the app's
/// point of view. So a failure is logged and the app continues with the cloud
/// features degraded and the offline outbox doing the work.
library;

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/logger.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Portrait only. The alert screen is read one-handed by someone who may be
  // injured; a layout that reflows on rotation mid-countdown is a hazard, and
  // landscape is not a sensible way to hold a phone in a car seat.
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);

  await _initCloud();

  runApp(const ProviderScope(child: SaasApp()));
}

/// Initialise Firebase, tolerating its absence.
Future<void> _initCloud() async {
  final AppLogger log = AppLogger();
  try {
    await Firebase.initializeApp();
  } on Object catch (error) {
    // Not fatal, and deliberately so. See the library docs.
    log.log(
      LogLevel.warning,
      'main',
      'Firebase unavailable — running offline. '
      'Accidents will be stored locally and uploaded when possible.',
      error,
    );
  }
}
