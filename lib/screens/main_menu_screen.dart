import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_theme.dart';
import '../game/constants.dart';
import '../widgets/menu_button.dart';
import 'game_screen.dart';
import 'info_webview_screen.dart';

class MainMenuScreen extends StatefulWidget {
  const MainMenuScreen({super.key});

  @override
  State<MainMenuScreen> createState() => _MainMenuScreenState();
}

class _MainMenuScreenState extends State<MainMenuScreen> {
  int _best = 0;
  File? _avatar;
  static const String _kAvatarPath = 'tf.menu.avatar.path';

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    _loadBest();
    _loadAvatar();
  }

  Future<void> _loadBest() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _best = prefs.getInt(kBestScoreKey) ?? 0);
  }

  Future<void> _loadAvatar() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_kAvatarPath);
    if (path != null && File(path).existsSync()) {
      if (mounted) setState(() => _avatar = File(path));
    }
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAvatarPath, picked.path);
    setState(() => _avatar = File(picked.path));
  }

  Future<void> _openGame() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const GameScreen()),
    );
    _loadBest();
  }

  Future<void> _openInfoPage(String url, String title) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InfoWebViewScreen(url: url, title: title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(kBgAsset, fit: BoxFit.cover),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.25),
                  Colors.black.withValues(alpha: 0.7),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  FractionallySizedBox(
                    widthFactor: 0.85,
                    child: Image.asset(kLogoNameAsset, fit: BoxFit.contain),
                  ),
                  const Spacer(flex: 2),
                  GestureDetector(
                    onTap: _pickAvatar,
                    child: Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white12,
                            border: Border.all(
                              color: kAccent.withValues(alpha: 0.6),
                              width: 2,
                            ),
                            image: _avatar != null
                                ? DecorationImage(
                                    image: FileImage(_avatar!),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          child: _avatar == null
                              ? const Icon(
                                  Icons.person,
                                  color: Colors.white38,
                                  size: 36,
                                )
                              : null,
                        ),
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: kAccent,
                          ),
                          child: const Icon(
                            Icons.camera_alt,
                            color: Colors.white,
                            size: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                    decoration: panelDecoration(radius: 14),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.emoji_events,
                            color: kAccent, size: 22),
                        const SizedBox(width: 10),
                        Text(
                          'BEST: $_best',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: MenuButton(
                      label: 'PLAY',
                      icon: Icons.play_arrow_rounded,
                      primary: true,
                      onTap: _openGame,
                    ),
                  ),
                  if (!Platform.isIOS) ...[
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: MenuButton(
                        label: 'EXIT',
                        icon: Icons.close_rounded,
                        onTap: () => SystemNavigator.pop(),
                      ),
                    ),
                  ],
                  const Spacer(flex: 1),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 10),
                    child: Text(
                      'TAP  TO  ROTATE   /   SWIPE  TO  MOVE',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _LinkText(
                          icon: Icons.shield_outlined,
                          label: 'Privacy Policy',
                          onTap: () => _openInfoPage(
                            kPrivacyPolicyUrl,
                            'Privacy Policy',
                          ),
                        ),
                        const SizedBox(width: 18),
                        Container(
                          width: 1,
                          height: 14,
                          color: Colors.white24,
                        ),
                        const SizedBox(width: 18),
                        _LinkText(
                          icon: Icons.help_outline_rounded,
                          label: 'Support',
                          onTap: () => _openInfoPage(
                            kSupportUrl,
                            'Support',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkText extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _LinkText({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: kAccent),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                letterSpacing: 1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
