import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const JapanoDictApp());
}

class JapanoDictApp extends StatelessWidget {
  const JapanoDictApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JapanoDict - Japanese Dictionary',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
