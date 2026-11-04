import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart';
import 'device_shell.dart';

/// The store's live menu with local prices and sold-out items. Ringing up
/// orders arrives with payments (roadmap step 3); for now staff can see the
/// menu and long-press an item to mark it sold out or back in stock.
class MenuScreen extends StatelessWidget {
  const MenuScreen({
    super.key,
    required this.device,
    required this.staff,
    required this.onLock,
  });
  final DeviceContext device;
  final StaffSession staff;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    final data = BackendScope.of(context).data;
    return Scaffold(
      appBar: AppBar(
        title: Text(staff.label),
        actions: [
          TextButton.icon(
            key: const Key('lock'),
            onPressed: onLock,
            icon: const Icon(Icons.lock_outline),
            label: const Text('Switch user'),
          ),
        ],
      ),
      body: StreamBuilder<List<MenuCategory>>(
        stream: data.menuCategories(device.orgId),
        builder: (context, cats) => StreamBuilder<List<MenuItem>>(
          stream: data.menuItems(device.orgId),
          builder: (context, items) => StreamBuilder<List<ModifierGroup>>(
            stream: data.modifierGroups(device.orgId),
            builder: (context, groups) => StreamBuilder<List<MenuOverride>>(
              stream: data.menuOverrides(device.orgId, device.locationId),
              builder: (context, overrides) {
                if (!cats.hasData ||
                    !items.hasData ||
                    !groups.hasData ||
                    !overrides.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final menu = buildLocationMenu(
                  categories: cats.data!,
                  items: items.data!,
                  modifierGroups: groups.data!,
                  overrides: overrides.data!,
                );
                if (menu.isEmpty) {
                  return const Center(
                    child: Text(
                      'No menu yet. An owner can add items in the manager app.',
                    ),
                  );
                }
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final section in menu) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          section.category.name,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final entry in section.items)
                            _ItemTile(device: device, entry: entry),
                        ],
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.device, required this.entry});
  final DeviceContext device;
  final LocationMenuItem entry;

  Future<void> _toggleSoldOut(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await BackendScope.of(context).data.saveMenuOverride(
        MenuOverride(
          itemId: entry.item.id,
          orgId: device.orgId,
          locationId: device.locationId,
          available: !entry.available,
        ),
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${entry.item.name} ${entry.available ? 'marked sold out' : 'back in stock'}',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 180,
      height: 120,
      child: Card(
        key: Key('item-${entry.item.id}'),
        color: entry.available
            ? null
            : theme.colorScheme.surfaceContainerHighest,
        child: InkWell(
          onLongPress: () => _toggleSoldOut(context),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                const Spacer(),
                Text(
                  entry.available ? formatCad(entry.priceCents) : 'Sold out',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
