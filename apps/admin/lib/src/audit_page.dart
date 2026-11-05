import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'widgets.dart';

/// Every platform admin action, newest first.
class AuditPage extends StatelessWidget {
  const AuditPage({super.key, required this.backend});
  final Backend backend;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Platform audit log')),
      body: StreamBuilder<List<AuditEntry>>(
        stream: backend.platform.platformAudit(limit: 200),
        builder: (context, snap) => snap.hasData
            ? SingleChildScrollView(child: AuditList(entries: snap.data!))
            : const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}
