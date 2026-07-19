import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const SmkApp());
}

class SmkApp extends StatelessWidget {
  const SmkApp({super.key});

  // Base URL configuration for the backend
  static const String apiBaseUrl = 'http://localhost:8080';
  static const String wsBaseUrl = 'ws://localhost:8080';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SMK (Smoke)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFF6366F1),
        scaffoldBackgroundColor: const Color(0xFF090D1A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1),
          secondary: Color(0xFFEC4899),
          surface: Color(0xFF1E293B),
        ),
        textTheme: GoogleFonts.interTextTheme(
          ThemeData.dark().textTheme,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
