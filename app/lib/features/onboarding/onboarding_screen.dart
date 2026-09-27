/// First-run onboarding: name the vehicle, add a contact.
///
/// Deliberately short. The only two things that change the system's behaviour
/// are "what is this for" (a name, so the SMS reads "Dad's car") and "who do we
/// call" (without which the app cannot do its job). Everything else has a
/// sensible default and lives in settings.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/providers.dart';
import '../../data/repositories/hospital_repository.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/spacing.dart';
import '../../domain/entities/accident.dart';
import '../../domain/entities/user_profile.dart';
import '../../widgets/ui_kit.dart';
import '../contacts/contacts_screen.dart';

/// The onboarding screen.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final PageController _pages = PageController();
  final TextEditingController _vehicle = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  int _page = 0;
  bool _busy = false;

  @override
  void dispose() {
    _pages.dispose();
    _vehicle.dispose();
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(Spacing.medium),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Row(
                      children: List<Widget>.generate(2, (int i) {
                        final bool done = i <= _page;
                        return Expanded(
                          child: Container(
                            height: 3,
                            margin: EdgeInsets.only(right: i == 0 ? Spacing.xxs : 0),
                            decoration: BoxDecoration(
                              color: done
                                  ? AppColors.electric
                                  : theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                  TextButton(
                    onPressed: _finish,
                    child: const Text('Skip'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (int i) => setState(() => _page = i),
                children: <Widget>[
                  _vehiclePage(context),
                  _contactPage(context),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(Spacing.medium),
              child: PrimaryAction(
                label: _page == 0 ? 'Next' : 'Finish setup',
                busy: _busy,
                onPressed: _next,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _vehiclePage(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(Spacing.large),
      children: <Widget>[
        const SizedBox(height: Spacing.xl),
        const Icon(Icons.directions_car_outlined, size: 52, color: AppColors.electric),
        const SizedBox(height: Spacing.large),
        Text(
          'What are we protecting?',
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          'Give the vehicle a name. It appears in the alert message your '
          'contacts receive, so "Dad\'s car" is more useful than "Vehicle 1".',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Spacing.large),
        TextField(
          controller: _vehicle,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Vehicle name',
            hintText: "Dad's car",
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  Widget _contactPage(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(Spacing.large),
      children: <Widget>[
        const SizedBox(height: Spacing.xl),
        const Icon(Icons.groups_outlined, size: 52, color: AppColors.emergency),
        const SizedBox(height: Spacing.large),
        Text(
          'Who should we call?',
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          'This is the only part of the system that reaches a person. Without a '
          'contact, a crash is recorded but nobody is told.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Spacing.large),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Their name',
            hintText: 'Anitha',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Spacing.sm),
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'Phone number',
            hintText: '+91 98765 43210',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Spacing.medium),
        OutlinedButton.icon(
          onPressed: _addMore,
          icon: const Icon(Icons.add),
          label: const Text('Add another contact later'),
        ),
      ],
    );
  }

  Future<void> _addMore() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => const ContactEditor(),
    );
  }

  Future<void> _next() async {
    if (_page == 0) {
      setState(() => _page = 1);
      return;
    }
    await _finish();
  }

  Future<void> _finish() async {
    setState(() => _busy = true);
    final String uid = ref.read(firestoreDatasourceProvider).currentUserId ?? 'anonymous';
    final ContactRepository contacts = ref.read(contactRepositoryProvider);

    await contacts.save(
      UserProfile(
        id: uid,
        name: _name.text.trim(),
        phone: '',
        vehicleNumber: _vehicle.text.trim(),
      ),
    );

    if (_name.text.trim().isNotEmpty && _phone.text.trim().isNotEmpty) {
      await contacts.addContact(
        EmergencyContact(
          id: 'c${DateTime.now().microsecondsSinceEpoch}',
          name: _name.text.trim(),
          phone: _phone.text.trim(),
        ),
      );
    }

    await ref.read(settingsRepositoryProvider).setOnboarded(true);
    if (!mounted) return;
    setState(() => _busy = false);
    context.goNamed(AppRoutes.home);
  }
}
