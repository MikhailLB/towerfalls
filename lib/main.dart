import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'screens/loading_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.immersiveSticky,
  );
  runApp(const TowerFallsApp());
}

class TowerFallsApp extends StatelessWidget {
  const TowerFallsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tower Falls',
      debugShowCheckedModeBanner: false,
      theme: buildTowerFallsTheme(),
      home: const LoadingScreen(),
    );
  }
}
