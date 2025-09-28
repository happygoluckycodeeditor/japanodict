import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const JapanoDictApp());
}

class JapanoDictApp extends StatelessWidget {
  const JapanoDictApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JapanoDict - Japanese Dictionary',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 2,
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
