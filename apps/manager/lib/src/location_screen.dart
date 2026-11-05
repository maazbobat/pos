import 'package:flutter/material.dart';

import 'app.dart';
import 'devices_tab.dart';
import 'menu_tab.dart';
import 'online_tab.dart';
import 'team_tab.dart';

/// One store. Managers get Team, Devices and Online ordering; everyone with
/// a role here sees the menu (and owners and managers can change it).
class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key, required this.store});
  final StoreContext store;

  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final tabs = <(String, IconData, Widget)>[
      if (store.isManager)
        ('Team', Icons.people_outline, TeamTab(store: store)),
      if (store.isManager)
        ('Devices', Icons.tablet_android, DevicesTab(store: store)),
      ('Menu', Icons.restaurant_menu, MenuTab(store: store)),
      if (store.isManager)
        ('Online', Icons.storefront_outlined, OnlineTab(store: store)),
    ];
    final index = _tab.clamp(0, tabs.length - 1);
    return Scaffold(
      appBar: AppBar(
        title: Text(store.location.name),
        bottom: store.canWrite
            ? null
            : const PreferredSize(
                preferredSize: Size.fromHeight(24),
                child: Text('Read-only: changes are paused for this store'),
              ),
      ),
      body: tabs[index].$3,
      bottomNavigationBar: tabs.length < 2
          ? null
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: [
                for (final t in tabs)
                  NavigationDestination(icon: Icon(t.$2), label: t.$1),
              ],
            ),
    );
  }
}
