/// Emergency contacts (PROJECT_PLAN §12, Screen 6).
///
/// Contacts are the *only* thing in this system that reaches a human being, so
/// the screen is built around one question: "if this happened right now, would
/// anyone be told?" An empty list therefore gets prominent, unmissable treatment
/// rather than a neutral empty state.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/spacing.dart';
import '../../domain/entities/accident.dart';
import '../../widgets/ui_kit.dart';
import 'contacts_state.dart';

/// The contacts list and editor.
class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key});

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  @override
  Widget build(BuildContext context) {
    final ContactsViewState state = ref.watch(contactsViewProvider);
    final List<EmergencyContact> contacts = state.contacts;

    return Scaffold(
      appBar: AppBar(title: const Text('Emergency contacts')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, null),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Add contact'),
      ),
      body: contacts.isEmpty
          ? EmptyState(
              icon: Icons.groups_outlined,
              title: 'No contacts yet',
              message: 'Without a contact, an alert can be recorded but nobody '
                  'will be told. Add at least one person who can reach you.',
              action: FilledButton.icon(
                onPressed: () => _edit(context, null),
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Add your first contact'),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(Spacing.medium),
              itemCount: contacts.length,
              separatorBuilder: (_, __) => const SizedBox(height: Spacing.xs),
              itemBuilder: (BuildContext context, int index) {
                final EmergencyContact contact = contacts[index];
                return ContactTile(
                  contact: contact,
                  // The primary call is the whole point of the list, so it is a
                  // full-width target rather than a small trailing icon.
                  onCall: () => ref.read(contactsViewProvider.notifier).call(contact),
                  onEdit: () => _edit(context, contact),
                  onDelete: () => _confirmDelete(context, contact),
                );
              },
            ),
    );
  }

  Future<void> _edit(BuildContext context, EmergencyContact? existing) async {
    final EmergencyContact? saved = await showModalBottomSheet<EmergencyContact>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => ContactEditor(existing: existing),
    );
    if (saved == null || !context.mounted) return;
    await ref.read(contactsViewProvider.notifier).save(saved);
  }

  Future<void> _confirmDelete(BuildContext context, EmergencyContact contact) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Remove ${contact.name}?'),
        content: const Text(
          'They will no longer be called or messaged during an alert.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.emergency),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    await ref.read(contactsViewProvider.notifier).remove(contact.id);
  }
}

/// One contact row.
class ContactTile extends StatelessWidget {
  const ContactTile({
    required this.contact,
    this.onCall,
    this.onEdit,
    this.onDelete,
    super.key,
  });

  final EmergencyContact contact;
  final VoidCallback? onCall;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool callable = contact.isCallable;

    return GlassCard(
      onTap: onEdit,
      child: Row(
        children: <Widget>[
          CircleAvatar(
            backgroundColor: AppColors.electric.withValues(alpha: 0.15),
            child: Text(
              contact.name.isEmpty ? '?' : contact.name.characters.first.toUpperCase(),
              style: const TextStyle(color: AppColors.electric, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  contact.name,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (contact.relationship != null &&
                    contact.relationship!.isNotEmpty) ...<Widget>[
                  Text(
                    contact.relationship!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 3),
                if (callable)
                  SelectableText(
                    contact.phone,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  )
                else
                  StatusPill(
                    label: 'No phone number',
                    severity: StatusSeverity.warning,
                    icon: Icons.phone_disabled,
                    dense: true,
                  ),
              ],
            ),
          ),
          if (callable)
            IconButton.filled(
              onPressed: onCall,
              icon: const Icon(Icons.call, size: 19),
              tooltip: 'Call ${contact.name}',
              style: IconButton.styleFrom(
                backgroundColor: AppColors.emergency.withValues(alpha: 0.15),
                foregroundColor: AppColors.emergency,
              ),
            ),
          IconButton(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline, size: 19),
            tooltip: 'Remove',
          ),
        ],
      ),
    );
  }
}

/// Add/edit sheet.
class ContactEditor extends StatefulWidget {
  const ContactEditor({this.existing, super.key});

  final EmergencyContact? existing;

  @override
  State<ContactEditor> createState() => _ContactEditorState();
}

class _ContactEditorState extends State<ContactEditor> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _phone =
      TextEditingController(text: widget.existing?.phone ?? '');
  late final TextEditingController _relationship =
      TextEditingController(text: widget.existing?.relationship ?? '');

  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _relationship.dispose();
    super.dispose();
  }

  void _save() {
    final String name = _name.text.trim();
    final String phone = _phone.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'A name is required.');
      return;
    }
    if (phone.isEmpty) {
      setState(() => _error = 'A phone number is required, or the contact cannot be called.');
      return;
    }
    Navigator.of(context).pop(
      EmergencyContact(
        // Keep the existing id so editing replaces rather than duplicates.
        id: widget.existing?.id ??
            'c${DateTime.now().microsecondsSinceEpoch.toString().substring(5)}',
        name: name,
        phone: phone,
        relationship: _relationship.text.trim().isEmpty
            ? null
            : _relationship.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      // `viewInsets.bottom` lifts the sheet above the keyboard, so the Save
      // button is reachable while typing.
      padding: EdgeInsets.fromLTRB(
        Spacing.medium,
        0,
        Spacing.medium,
        MediaQuery.viewInsetsOf(context).bottom + Spacing.medium,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            widget.existing == null ? 'Add contact' : 'Edit contact',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: Spacing.medium),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Name',
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
          const SizedBox(height: Spacing.sm),
          TextField(
            controller: _relationship,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Relationship (optional)',
              hintText: 'Mother, colleague, neighbour…',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: Spacing.sm),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.emergency),
            ),
          ],
          const SizedBox(height: Spacing.large),
          PrimaryAction(
            label: 'Save contact',
            icon: Icons.check,
            onPressed: _save,
          ),
        ],
      ),
    );
  }
}
