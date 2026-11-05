import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart';

/// The store's own ordering site: its web address, how guests pay, the
/// pickup lead time, and a pause switch for busy times. Changes go through
/// the updateOnlineOrdering Function, which keeps web addresses unique and
/// lets only the owner set the Stripe account online payments go to.
class OnlineTab extends StatelessWidget {
  const OnlineTab({super.key, required this.store});
  final StoreContext store;

  /// Where guests order. Set per deployment once the site is hosted.
  static const siteUrl = String.fromEnvironment(
    'ORDERING_SITE_URL',
    defaultValue: 'http://localhost:8083',
  );

  @override
  Widget build(BuildContext context) {
    final orders = BackendScope.of(context).orders;
    return StreamBuilder<OnlineOrderingSettings?>(
      stream: orders.onlineOrdering(store.org.id, store.location.id),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return _OnlineForm(
          key: ValueKey(snap.data?.slug),
          store: store,
          settings: snap.data ?? const OnlineOrderingSettings(),
        );
      },
    );
  }
}

class _OnlineForm extends StatefulWidget {
  const _OnlineForm({super.key, required this.store, required this.settings});
  final StoreContext store;
  final OnlineOrderingSettings settings;

  @override
  State<_OnlineForm> createState() => _OnlineFormState();
}

class _OnlineFormState extends State<_OnlineForm> {
  late final _slug = TextEditingController(
    text: widget.settings.slug ?? _suggestSlug(),
  );
  late final _lead = TextEditingController(
    text: '${widget.settings.pickupLeadMinutes}',
  );
  late final _stripe = TextEditingController(
    text: widget.settings.stripeAccountId ?? '',
  );
  var _busy = false;

  String _suggestSlug() =>
      '${widget.store.org.name}-${widget.store.location.name}'
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
          .replaceAll(RegExp(r'^-+|-+$'), '');

  @override
  void dispose() {
    _slug.dispose();
    _lead.dispose();
    _stripe.dispose();
    super.dispose();
  }

  Future<void> _save({
    bool? enabled,
    bool? paused,
    bool? payAtPickup,
    bool? payOnline,
    bool fields = false,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final s = widget.settings;
    final lead = int.tryParse(_lead.text.trim());
    if (fields && (lead == null || lead < 0 || lead > 240)) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Pickup lead time is 0 to 240 minutes.')),
      );
      return;
    }
    final slug = _slug.text.trim().toLowerCase();
    final stripe = _stripe.text.trim();
    setState(() => _busy = true);
    try {
      await BackendScope.of(context).orders.updateOnlineOrdering(
        widget.store.org.id,
        widget.store.location.id,
        enabled: enabled,
        paused: paused,
        payAtPickup: payAtPickup,
        payOnline: payOnline,
        slug: fields || (enabled == true && s.slug == null) ? slug : null,
        pickupLeadMinutes: fields ? lead : null,
        stripeAccountId:
            fields &&
                widget.store.isOwner &&
                stripe != (s.stripeAccountId ?? '')
            ? stripe
            : null,
      );
      messenger.showSnackBar(const SnackBar(content: Text('Saved.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.settings;
    final store = widget.store;
    final canEdit = store.isManager && store.canWrite && !_busy;
    final link = s.slug == null ? null : '${OnlineTab.siteUrl}/#/${s.slug}';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Guests order ahead for pickup on this store\'s own page. '
          'Orders appear on the POS and kitchen display.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const Key('online-enabled'),
          title: const Text('Take online orders'),
          subtitle: link == null ? null : SelectableText(link),
          value: s.enabled,
          onChanged: canEdit ? (v) => _save(enabled: v) : null,
        ),
        SwitchListTile(
          key: const Key('online-paused'),
          title: const Text('Paused'),
          subtitle: const Text(
            'Stops new orders for a while. Staff can also pause from the POS.',
          ),
          value: s.paused,
          onChanged: s.enabled && store.canWrite && !_busy
              ? (v) => _save(paused: v)
              : null,
        ),
        const Divider(),
        TextField(
          key: const Key('online-slug'),
          controller: _slug,
          enabled: canEdit,
          decoration: InputDecoration(
            labelText: 'Web address',
            prefixText: '${OnlineTab.siteUrl}/#/',
            helperText: 'Lowercase letters, numbers and hyphens.',
          ),
        ),
        TextField(
          key: const Key('online-lead'),
          controller: _lead,
          enabled: canEdit,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Earliest pickup, in minutes after ordering',
          ),
        ),
        SwitchListTile(
          title: const Text('Guests can pay at pickup'),
          value: s.payAtPickup,
          onChanged: canEdit ? (v) => _save(payAtPickup: v) : null,
        ),
        SwitchListTile(
          title: const Text('Guests can pay online by card'),
          subtitle: Text(
            s.stripeAccountId == null
                ? 'Needs the restaurant\'s Stripe account first.'
                : 'Paid to ${s.stripeAccountId} through Stripe Checkout.',
          ),
          value: s.payOnline,
          onChanged: canEdit && s.stripeAccountId != null
              ? (v) => _save(payOnline: v)
              : null,
        ),
        if (store.isOwner)
          TextField(
            key: const Key('online-stripe'),
            controller: _stripe,
            enabled: canEdit,
            decoration: const InputDecoration(
              labelText: 'Stripe account ID (owner only)',
              hintText: 'acct_…',
              helperText: 'The restaurant\'s own Stripe account, where online payments go.',
            ),
          ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: const Key('online-save'),
            onPressed: canEdit ? () => _save(fields: true) : null,
            child: const Text('Save'),
          ),
        ),
      ],
    );
  }
}
