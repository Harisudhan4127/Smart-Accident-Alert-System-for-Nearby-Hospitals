/// The contacts screen's state.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../../core/di/providers.dart';
import '../../data/repositories/hospital_repository.dart';
import '../../domain/entities/accident.dart';
import '../../domain/entities/user_profile.dart';

/// What the contacts screen shows.
@immutable
class ContactsViewState {
  const ContactsViewState({this.contacts = const <EmergencyContact>[], this.busy = false});

  final List<EmergencyContact> contacts;
  final bool busy;

  /// Contacts that can actually be dialled.
  List<EmergencyContact> get callable =>
      contacts.where((EmergencyContact c) => c.isCallable).toList(growable: false);
}

/// Drives the contacts screen.
class ContactsViewController extends Notifier<ContactsViewState> {
  StreamSubscription<UserProfile?>? _sub;

  @override
  ContactsViewState build() {
    final ContactRepository repo = ref.read(contactRepositoryProvider);

    // Seed from whatever is already loaded so the first frame is not empty.
    final UserProfile? cached = repo.profile;
    final List<EmergencyContact> initial =
        cached?.emergencyContacts ?? const <EmergencyContact>[];

    _sub = repo.profileStream.listen((UserProfile? profile) {
      state = ContactsViewState(
        contacts: profile?.emergencyContacts ?? const <EmergencyContact>[],
      );
    });

    ref.onDispose(() => unawaited(_sub?.cancel()));
    unawaited(repo.load());

    return ContactsViewState(contacts: initial);
  }

  /// Add or replace a contact.
  Future<bool> save(EmergencyContact contact) async {
    state = ContactsViewState(contacts: state.contacts, busy: true);
    final bool ok =
        (await ref.read(contactRepositoryProvider).addContact(contact)).isOk;
    state = ContactsViewState(contacts: state.contacts, busy: false);
    return ok;
  }

  /// Remove a contact.
  Future<bool> remove(String contactId) async {
    state = ContactsViewState(contacts: state.contacts, busy: true);
    final bool ok =
        (await ref.read(contactRepositoryProvider).removeContact(contactId)).isOk;
    state = ContactsViewState(contacts: state.contacts, busy: false);
    return ok;
  }

  /// Call a contact.
  Future<void> call(EmergencyContact contact) =>
      ref.read(mapsDatasourceProvider).call(contact.phone);
}

/// The contacts screen's state.
final NotifierProvider<ContactsViewController, ContactsViewState>
    contactsViewProvider =
    NotifierProvider<ContactsViewController, ContactsViewState>(
  ContactsViewController.new,
);
