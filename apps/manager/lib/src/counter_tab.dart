import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart';

/// The counter's hardware: Stripe card readers, Epson printers (and the cash
/// drawer plugged into one), and what goes on receipts. Managers only.
class CounterTab extends StatelessWidget {
  const CounterTab({super.key, required this.store});
  final StoreContext store;

  @override
  Widget build(BuildContext context) {
    final backend = BackendScope.of(context);
    final o = store.org.id, l = store.location.id;
    return StreamBuilder<PaymentSettings>(
      stream: backend.counter.paymentSettings(o, l),
      builder: (context, pay) => StreamBuilder<HardwareSettings>(
        stream: backend.counter.hardware(o, l),
        builder: (context, hw) => StreamBuilder<OnlineOrderingSettings?>(
          stream: backend.orders.onlineOrdering(o, l),
          builder: (context, online) {
            if (!pay.hasData || !hw.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return _CounterView(
              store: store,
              payments: pay.data!,
              hardware: hw.data!,
              stripeConnected: online.data?.stripeAccountId != null,
            );
          },
        ),
      ),
    );
  }
}

class _CounterView extends StatelessWidget {
  const _CounterView({
    required this.store,
    required this.payments,
    required this.hardware,
    required this.stripeConnected,
  });
  final StoreContext store;
  final PaymentSettings payments;
  final HardwareSettings hardware;
  final bool stripeConnected;

  bool get canEdit => store.canWrite;

  Future<void> _save(BuildContext context, HardwareSettings next) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await BackendScope.of(context).counter
          .saveHardware(store.org.id, store.location.id, next);
      messenger.showSnackBar(const SnackBar(content: Text('Saved.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  HardwareSettings _with({
    List<PrinterConfig>? printers,
    ReceiptSettings? receipt,
    bool? autoPrintReceipt,
    bool? autoPrintKitchen,
  }) => HardwareSettings(
    printers: printers ?? hardware.printers,
    receipt: receipt ?? hardware.receipt,
    autoPrintReceipt: autoPrintReceipt ?? hardware.autoPrintReceipt,
    autoPrintKitchen: autoPrintKitchen ?? hardware.autoPrintKitchen,
  );

  Future<void> _editPrinter(
    BuildContext context,
    PrinterConfig? existing,
  ) async {
    final result = await showDialog<PrinterConfig>(
      context: context,
      builder: (_) => PrinterDialog(
        existing: existing,
        taken: {for (final p in hardware.printers) p.id},
      ),
    );
    if (result == null || !context.mounted) return;
    await _save(
      context,
      _with(
        printers: [
          for (final p in hardware.printers)
            if (p.id != result.id) p,
          result,
        ],
      ),
    );
  }

  Future<void> _addReader(BuildContext context) async {
    final added = await showDialog<CardReader>(
      context: context,
      builder: (_) =>
          ReaderDialog(store: store, firstReader: payments.readers.isEmpty),
    );
    if (added != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${added.name} is ready to take cards.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Card readers', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Stripe smart readers (Stripe Reader S700, BBPOS WisePOS E) take Visa, '
          'Mastercard, Amex and Interac. Payments go to the restaurant\'s own Stripe account.',
          style: theme.textTheme.bodySmall,
        ),
        for (final r in payments.readers)
          ListTile(
            key: Key('reader-${r.id}'),
            leading: const Icon(Icons.contactless_outlined),
            title: Text(r.name),
            subtitle: Text(_readerModel(r.model)),
          ),
        if (payments.readers.isEmpty)
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('No card reader yet. The POS takes cash only.'),
          ),
        if (!stripeConnected)
          ListTile(
            leading: const Icon(Icons.link_off),
            title: const Text('Connect Stripe first'),
            subtitle: Text(
              store.isOwner
                  ? 'Enter the restaurant\'s Stripe account in the Online tab.'
                  : 'The owner enters the restaurant\'s Stripe account in the Online tab.',
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('add-reader'),
            onPressed: canEdit && stripeConnected
                ? () => _addReader(context)
                : null,
            icon: const Icon(Icons.add),
            label: const Text('Add a card reader'),
          ),
        ),
        const Divider(height: 32),
        Text('Printers', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Epson TM receipt printers on the store network (TM-m30III, TM-T88VII, TM-T20III and similar). '
          'Plug the cash drawer into the receipt printer\'s drawer port.',
          style: theme.textTheme.bodySmall,
        ),
        for (final p in hardware.printers)
          ListTile(
            key: Key('printer-${p.id}'),
            leading: Icon(
              p.jobs.contains(PrinterJob.kitchen)
                  ? Icons.soup_kitchen_outlined
                  : Icons.receipt_long_outlined,
            ),
            title: Text(p.name),
            subtitle: Text(
              [
                '${p.host} · ${p.connection == PrinterConnection.epos ? 'ePOS' : 'raw 9100'} · ${p.paperMm} mm',
                [
                  if (p.jobs.contains(PrinterJob.receipt)) 'receipts',
                  if (p.jobs.contains(PrinterJob.kitchen))
                    p.stations.isEmpty
                        ? 'kitchen (all items)'
                        : 'kitchen: ${p.stations.join(', ')}',
                  if (p.hasDrawer) 'cash drawer',
                ].join(', '),
              ].join('\n'),
            ),
            isThreeLine: true,
            onTap: canEdit ? () => _editPrinter(context, p) : null,
            trailing: canEdit
                ? IconButton(
                    key: Key('remove-printer-${p.id}'),
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _save(
                      context,
                      _with(
                        printers: [
                          for (final x in hardware.printers)
                            if (x.id != p.id) x,
                        ],
                      ),
                    ),
                  )
                : null,
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('add-printer'),
            onPressed: canEdit ? () => _editPrinter(context, null) : null,
            icon: const Icon(Icons.add),
            label: const Text('Add a printer'),
          ),
        ),
        SwitchListTile(
          key: const Key('auto-receipt'),
          title: const Text('Print a receipt after every sale'),
          subtitle: const Text('Otherwise the POS offers "Print receipt".'),
          value: hardware.autoPrintReceipt,
          onChanged: canEdit
              ? (v) => _save(context, _with(autoPrintReceipt: v))
              : null,
        ),
        SwitchListTile(
          key: const Key('auto-kitchen'),
          title: const Text('Print kitchen tickets for each order'),
          value: hardware.autoPrintKitchen,
          onChanged: canEdit
              ? (v) => _save(context, _with(autoPrintKitchen: v))
              : null,
        ),
        const Divider(height: 32),
        _ReceiptForm(
          key: ValueKey(hardware.receipt.toMap().toString()),
          receipt: hardware.receipt,
          enabled: canEdit,
          onSave: (r) => _save(context, _with(receipt: r)),
        ),
      ],
    );
  }
}

String _readerModel(String? model) => switch (model) {
  'stripe_s700' => 'Stripe Reader S700',
  'bbpos_wisepos_e' => 'BBPOS WisePOS E',
  'simulated_wisepos_e' => 'Simulated reader (test mode)',
  null => 'Stripe reader',
  final m => m,
};

class _ReceiptForm extends StatefulWidget {
  const _ReceiptForm({
    super.key,
    required this.receipt,
    required this.enabled,
    required this.onSave,
  });
  final ReceiptSettings receipt;
  final bool enabled;
  final ValueChanged<ReceiptSettings> onSave;

  @override
  State<_ReceiptForm> createState() => _ReceiptFormState();
}

class _ReceiptFormState extends State<_ReceiptForm> {
  late final _header = TextEditingController(
    text: widget.receipt.header.join('\n'),
  );
  late final _tax = TextEditingController(text: widget.receipt.taxNumber ?? '');
  late final _footer = TextEditingController(text: widget.receipt.footer ?? '');

  @override
  void dispose() {
    _header.dispose();
    _tax.dispose();
    _footer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Receipt', style: Theme.of(context).textTheme.titleMedium),
        TextField(
          key: const Key('receipt-header'),
          controller: _header,
          enabled: widget.enabled,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Lines under the store name',
            hintText: 'Address, phone, website',
          ),
        ),
        TextField(
          key: const Key('receipt-tax'),
          controller: _tax,
          enabled: widget.enabled,
          decoration: const InputDecoration(
            labelText: 'GST/HST registration number',
            hintText: '123456789 RT0001',
          ),
        ),
        TextField(
          key: const Key('receipt-footer'),
          controller: _footer,
          enabled: widget.enabled,
          decoration: const InputDecoration(labelText: 'Bottom line'),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('receipt-save'),
          onPressed: widget.enabled
              ? () => widget.onSave(
                  ReceiptSettings(
                    header: [
                      for (final l in _header.text.split('\n'))
                        if (l.trim().isNotEmpty) l.trim(),
                    ],
                    taxNumber: _tax.text.trim().isEmpty
                        ? null
                        : _tax.text.trim(),
                    footer: _footer.text.trim().isEmpty
                        ? null
                        : _footer.text.trim(),
                  ),
                )
              : null,
          child: const Text('Save receipt'),
        ),
      ],
    );
  }
}

/// Adds or edits a printer.
class PrinterDialog extends StatefulWidget {
  const PrinterDialog({super.key, this.existing, this.taken = const {}});
  final PrinterConfig? existing;
  final Set<String> taken;

  @override
  State<PrinterDialog> createState() => _PrinterDialogState();
}

class _PrinterDialogState extends State<PrinterDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _host = TextEditingController(text: widget.existing?.host ?? '');
  late final _stations = TextEditingController(
    text: widget.existing?.stations.join(', ') ?? '',
  );
  late var _connection = widget.existing?.connection ?? PrinterConnection.epos;
  late var _paper = widget.existing?.paperMm ?? 80;
  late var _jobs = {
    ...widget.existing?.jobs ?? {PrinterJob.receipt},
  };
  late var _drawer = widget.existing?.hasDrawer ?? false;
  late var _https = widget.existing?.https ?? false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _stations.dispose();
    super.dispose();
  }

  String _newId(String name) {
    final base = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    var id = base.isEmpty ? 'printer' : base;
    for (var n = 2; widget.taken.contains(id); n++) {
      id = '$base-$n';
    }
    return id;
  }

  void _submit() {
    final name = _name.text.trim();
    final host = _host.text.trim();
    if (name.isEmpty) {
      return setState(() => _error = 'Give the printer a name.');
    }
    if (!RegExp(r'^[A-Za-z0-9.-]{1,253}$').hasMatch(host)) {
      return setState(
        () => _error =
            'Enter the printer\'s IP address, for example 192.168.1.50.',
      );
    }
    if (_jobs.isEmpty) {
      return setState(() => _error = 'Pick receipts, kitchen tickets or both.');
    }
    Navigator.of(context).pop(
      PrinterConfig(
        id: widget.existing?.id ?? _newId(name),
        name: name,
        host: host,
        connection: _connection,
        https: _connection == PrinterConnection.epos && _https,
        paperMm: _paper,
        jobs: _jobs,
        stations: _jobs.contains(PrinterJob.kitchen)
            ? [
                for (final s in _stations.text.split(','))
                  if (s.trim().isNotEmpty) s.trim().toLowerCase(),
              ]
            : const [],
        hasDrawer: _drawer,
      ),
    );
  }

  void _toggleJob(PrinterJob j, bool on) =>
      setState(() => _jobs = on ? {..._jobs, j} : ({..._jobs}..remove(j)));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.existing == null
            ? 'Add a printer'
            : 'Edit ${widget.existing!.name}',
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('printer-name'),
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Front counter',
                ),
              ),
              TextField(
                key: const Key('printer-host'),
                controller: _host,
                decoration: const InputDecoration(
                  labelText: 'IP address',
                  hintText: '192.168.1.50',
                  helperText: 'Hold the printer\'s feed button at power-on to print it. Reserve it in the router.',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<PrinterConnection>(
                segments: const [
                  ButtonSegment(
                    value: PrinterConnection.epos,
                    label: Text('Epson ePOS'),
                  ),
                  ButtonSegment(
                    value: PrinterConnection.raw,
                    label: Text('Raw (port 9100)'),
                  ),
                ],
                selected: {_connection},
                onSelectionChanged: (s) =>
                    setState(() => _connection = s.single),
              ),
              Text(
                _connection == PrinterConnection.epos
                    ? 'Works on the tablets and in a browser. Turn on ePOS-Print in the printer\'s web settings.'
                    : 'Android POS app only. Works with any ESC/POS network printer.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_connection == PrinterConnection.epos)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use HTTPS'),
                  subtitle: const Text(
                    'Only if the POS runs in a browser on an https page.',
                  ),
                  value: _https,
                  onChanged: (v) => setState(() => _https = v ?? false),
                ),
              const SizedBox(height: 8),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 80, label: Text('80 mm paper')),
                  ButtonSegment(value: 58, label: Text('58 mm paper')),
                ],
                selected: {_paper},
                onSelectionChanged: (s) => setState(() => _paper = s.single),
              ),
              CheckboxListTile(
                key: const Key('printer-receipts'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Guest receipts'),
                value: _jobs.contains(PrinterJob.receipt),
                onChanged: (v) => _toggleJob(PrinterJob.receipt, v ?? false),
              ),
              CheckboxListTile(
                key: const Key('printer-kitchen'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Kitchen tickets'),
                value: _jobs.contains(PrinterJob.kitchen),
                onChanged: (v) => _toggleJob(PrinterJob.kitchen, v ?? false),
              ),
              if (_jobs.contains(PrinterJob.kitchen))
                TextField(
                  key: const Key('printer-stations'),
                  controller: _stations,
                  decoration: const InputDecoration(
                    labelText: 'Kitchen stations (optional)',
                    hintText: 'bar, kitchen',
                    helperText: 'Only items for these stations print here. Leave empty for every item.',
                    helperMaxLines: 2,
                  ),
                ),
              CheckboxListTile(
                key: const Key('printer-drawer'),
                contentPadding: EdgeInsets.zero,
                title: const Text('A cash drawer is plugged into this printer'),
                value: _drawer,
                onChanged: (v) => setState(() => _drawer = v ?? false),
              ),
              if (_error case final e?)
                Text(
                  e,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('printer-save'),
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Pairs a Stripe smart reader: the manager reads three words off the reader.
class ReaderDialog extends StatefulWidget {
  const ReaderDialog({
    super.key,
    required this.store,
    required this.firstReader,
  });
  final StoreContext store;
  final bool firstReader;

  @override
  State<ReaderDialog> createState() => _ReaderDialogState();
}

class _ReaderDialogState extends State<ReaderDialog> {
  final _name = TextEditingController(text: 'Front counter');
  final _code = TextEditingController();
  final _line1 = TextEditingController();
  final _city = TextEditingController();
  final _postal = TextEditingController();
  String? _error;
  var _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _code, _line1, _city, _postal]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final code = _code.text.trim().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      '-',
    );
    if (name.isEmpty || code.isEmpty) {
      return setState(
        () => _error = 'Enter a name and the words the reader shows.',
      );
    }
    final id = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final reader = await BackendScope.of(context).counter.registerCardReader(
        widget.store.org.id,
        widget.store.location.id,
        readerId: id.isEmpty ? 'reader' : id,
        name: name,
        registrationCode: code,
        addressLine1: widget.firstReader ? _line1.text.trim() : null,
        city: widget.firstReader ? _city.text.trim() : null,
        postalCode: widget.firstReader ? _postal.text.trim() : null,
      );
      if (mounted) Navigator.of(context).pop(reader);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a card reader'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'On the reader, open Settings and choose "Generate pairing code". '
                'Type the three words it shows.',
              ),
              TextField(
                key: const Key('reader-name'),
                controller: _name,
                decoration: const InputDecoration(labelText: 'Which counter'),
              ),
              TextField(
                key: const Key('reader-code'),
                controller: _code,
                decoration: const InputDecoration(
                  labelText: 'Pairing code',
                  hintText: 'apple-grape-orange',
                ),
              ),
              if (widget.firstReader) ...[
                const SizedBox(height: 12),
                const Text('Stripe needs the store\'s address once.'),
                TextField(
                  key: const Key('reader-line1'),
                  controller: _line1,
                  decoration: const InputDecoration(
                    labelText: 'Street address',
                  ),
                ),
                TextField(
                  key: const Key('reader-city'),
                  controller: _city,
                  decoration: const InputDecoration(labelText: 'City'),
                ),
                TextField(
                  key: const Key('reader-postal'),
                  controller: _postal,
                  decoration: const InputDecoration(labelText: 'Postal code'),
                ),
              ],
              if (_error case final e?)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    e,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('reader-save'),
          onPressed: _busy ? null : _submit,
          child: const Text('Pair reader'),
        ),
      ],
    );
  }
}
