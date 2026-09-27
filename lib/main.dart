import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() => runApp(const AshukuApp());

const _seed = Color(0xFF5B6CFF);

class AshukuApp extends StatelessWidget {
  const AshukuApp({super.key});

  ThemeData _theme(ColorScheme scheme) => ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    cardTheme: const CardThemeData(margin: EdgeInsets.zero),
  );

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (light, dark) => MaterialApp(
        title: 'Ashuku',
        debugShowCheckedModeBanner: false,
        theme: _theme(light?.harmonized() ?? ColorScheme.fromSeed(seedColor: _seed)),
        darkTheme: _theme(
          dark?.harmonized() ?? ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
