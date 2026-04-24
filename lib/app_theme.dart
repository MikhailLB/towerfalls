import 'package:flutter/material.dart';

const Color kAccent = Color(0xFFE6A93A);
const Color kAccentDark = Color(0xFF6B4A1A);
const Color kPanel = Color(0xCC0E0E14);

ThemeData buildTowerFallsTheme() {
  const base = ColorScheme.dark(
    primary: kAccent,
    secondary: kAccent,
    surface: Color(0xFF111218),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: base,
    scaffoldBackgroundColor: Colors.black,
    textTheme: const TextTheme(
      headlineMedium: TextStyle(
        fontWeight: FontWeight.w800,
        color: kAccent,
        letterSpacing: 1.2,
      ),
      titleLarge: TextStyle(
        fontWeight: FontWeight.w700,
        color: Colors.white,
      ),
      bodyMedium: TextStyle(color: Colors.white),
    ),
  );
}

BoxDecoration panelDecoration({double radius = 18}) => BoxDecoration(
      color: kPanel,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: kAccent.withValues(alpha: 0.6), width: 2),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.6),
          blurRadius: 16,
          offset: const Offset(0, 6),
        ),
      ],
    );
