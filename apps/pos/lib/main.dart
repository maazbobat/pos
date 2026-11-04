import 'package:flutter/material.dart';

void main() {
  runApp(const App());
}

/// Placeholder until onboarding (roadmap step 2) adds real screens.
class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'POS',
      home: Scaffold(body: Center(child: Text('POS'))),
    );
  }
}
