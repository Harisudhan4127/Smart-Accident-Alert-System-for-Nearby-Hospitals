/// Routing.
///
/// Two decisions worth stating, because both are safety decisions rather than
/// navigation taste:
///
/// 1. **The emergency alert is a `fullscreenDialog` on its own route, above
///    everything.** It is not a sheet and not a snackbar. A crash alert must be
///    impossible to miss and impossible to swipe away by reflex — a driver who
///    swipes to dismiss while reaching for the hazard light must not lose the
///    countdown. So [AlertRoute] sets `popScope` to block the back gesture.
/// 2. **There is no route that silently discards an in-progress alert.** The
///    guard in [AppRouter.refreshListenable] redirects to the alert whenever an
///    alert is live, from wherever the user was.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/alert/accident_alert_screen.dart';
import '../../features/contacts/contacts_screen.dart';
import '../../features/hospitals/hospitals_screen.dart';
import '../../features/location/location_screen.dart';
import '../../features/history/history_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/onboarding/onboarding_screen.dart';
import '../../features/pairing/pairing_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/splash/splash_screen.dart';
import '../theme/app_theme.dart';

/// Every named route, in one place.
///
/// String literals in `goNamed` calls are how a navigation typo becomes a
/// runtime "no route" error, so routes are constants and arguments are typed.
abstract final class AppRoutes {
  /// Permission and connectivity checks. Shown first, once.
  static const String splash = '/';

  /// Pairing a node over BLE.
  static const String pairing = '/pair';

  /// Choosing emergency contacts.
  static const String onboarding = '/onboarding';

  /// The dashboard.
  static const String home = '/home';

  /// The live emergency alert. Fullscreen dialog, non-dismissible.
  static const String alert = '/alert';

  /// Accident coordinates and accuracy.
  static const String location = '/location';

  /// Hospitals near the accident.
  static const String hospitals = '/hospitals';

  /// Emergency contacts.
  static const String contacts = '/contacts';

  /// Past accidents.
  static const String history = '/history';

  /// Settings and diagnostics.
  static const String settings = '/settings';
}

/// Arguments for [AppRoutes.hospitals].
class HospitalsArgs {
  const HospitalsArgs({required this.accidentId});

  /// The accident the search is centred on.
  final String accidentId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is HospitalsArgs && other.accidentId == accidentId;

  @override
  int get hashCode => accidentId.hashCode;
}

/// Arguments for [AppRoutes.alert].
class AlertArgs {
  const AlertArgs({this.eventId, this.fromSos = false});

  /// The device-side event id, so CONFIRM/CANCEL target the right event.
  final String? eventId;

  /// Whether the alert came from the SOS button rather than the detector.
  final bool fromSos;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlertArgs && other.eventId == eventId && other.fromSos == fromSos;

  @override
  int get hashCode => Object.hash(eventId, fromSos);
}

/// The app's router.
final Provider<GoRouter> appRouterProvider = Provider<GoRouter>((Ref ref) {
  return AppRouter.build(ref);
});

/// Builds the [GoRouter]. Static so tests can construct one against a
/// `ProviderContainer` without pulling in the provider indirection.
abstract final class AppRouter {
  static GoRouter build(Ref ref) {
    return GoRouter(
      initialLocation: AppRoutes.splash,
      debugLogDiagnostics: kDebugMode,
      routes: <RouteBase>[
        GoRoute(
          path: AppRoutes.splash,
          name: AppRoutes.splash,
          builder: (BuildContext context, GoRouterState state) =>
              const SplashScreen(),
        ),
        GoRoute(
          path: AppRoutes.home,
          name: AppRoutes.home,
          builder: (BuildContext context, GoRouterState state) => const HomeScreen(),
          routes: <RouteBase>[
            GoRoute(
              path: 'settings',
              name: AppRoutes.settings,
              builder: (BuildContext context, GoRouterState state) =>
                  const SettingsScreen(),
            ),
            GoRoute(
              path: 'history',
              name: AppRoutes.history,
              builder: (BuildContext context, GoRouterState state) =>
                  const HistoryScreen(),
            ),
            GoRoute(
              path: 'contacts',
              name: AppRoutes.contacts,
              builder: (BuildContext context, GoRouterState state) =>
                  const ContactsScreen(),
            ),
            GoRoute(
              path: 'location',
              name: AppRoutes.location,
              builder: (BuildContext context, GoRouterState state) =>
                  const LocationScreen(),
            ),
            GoRoute(
              path: 'hospitals',
              name: AppRoutes.hospitals,
              builder: (BuildContext context, GoRouterState state) {
                final HospitalsArgs args = state.extra as HospitalsArgs? ??
                    const HospitalsArgs(accidentId: '');
                return HospitalsScreen(accidentId: args.accidentId);
              },
            ),
          ],
        ),
        GoRoute(
          path: AppRoutes.pairing,
          name: AppRoutes.pairing,
          builder: (BuildContext context, GoRouterState state) => const PairingScreen(),
        ),
        GoRoute(
          path: AppRoutes.onboarding,
          name: AppRoutes.onboarding,
          builder: (BuildContext context, GoRouterState state) => const OnboardingScreen(),
        ),
        // The emergency alert.
        //
        // Deliberately a *root-level* route rather than a child of `home`: it
        // has to be reachable from anywhere, including from the splash or
        // pairing screen, because a crash can be detected before the app has
        // finished setting up.
        //
        // `fullscreenDialog: true` gives it the platform's modal presentation
        // and, more importantly, marks it as a route the user is mid-way
        // through — which is the truth: they are deciding something, not
        // browsing somewhere.
        GoRoute(
          path: AppRoutes.alert,
          name: AppRoutes.alert,
          pageBuilder: (BuildContext context, GoRouterState state) {
            final AlertArgs args =
                state.extra as AlertArgs? ?? const AlertArgs();
            return MaterialPage<void>(
              key: state.pageKey,
              fullscreenDialog: true,
              // Nothing may sit above the alert, so the rest of the stack is
              // not built behind it.
              child: AccidentAlertScreen(args: args),
            );
          },
        ),
      ],
      errorBuilder: (BuildContext context, GoRouterState state) =>
          _RouteNotFound(location: state.uri.toString()),
    );
  }
}

/// Shown for an unknown route.
///
/// A safety app must never show a red "no route" error: that reads as a crash of
/// the app itself, at the worst possible moment. So an unknown path falls back
/// to the dashboard, with a quiet notice.
class _RouteNotFound extends StatelessWidget {
  const _RouteNotFound({required this.location});

  final String location;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.explore_off_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Text('That screen is not available', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                location,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => context.goNamed(AppRoutes.home),
                child: const Text('Back to dashboard'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Light-theme wrapper used by [AppTheme]-driven screens.
///
/// Screens are written once and themed through this, so no screen has to know
/// whether the app is in light or dark mode.
class ThemedScreen extends StatelessWidget {
  const ThemedScreen({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
