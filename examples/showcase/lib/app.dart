import 'package:flutter/material.dart';

import 'pages/counter_page.dart';
import 'pages/downloads_page.dart';
import 'pages/player_page.dart';

class ShowcaseApp extends StatelessWidget {
  const ShowcaseApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'nativebind showcase',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  static const _titles = ['Counter', 'Player', 'Downloads'];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(_titles[_tab])),
        body: IndexedStack(
          index: _tab,
          children: const [CounterPage(), PlayerPage(), DownloadsPage()],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.exposure_plus_1), label: 'Counter'),
            NavigationDestination(icon: Icon(Icons.music_note), label: 'Player'),
            NavigationDestination(icon: Icon(Icons.download), label: 'Downloads'),
          ],
        ),
      );
}
