import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/launch_route.dart';

/// Persistence layer for the gray flow. Mixes SharedPreferences for quick
/// non-sensitive flags and FlutterSecureStorage for the cached destination
/// URL and the one-shot push target.
class RuntimeCache {
  // Storage keys are namespaced under `gray.` to avoid collisions with the
  // host app's own SharedPreferences / FlutterSecureStorage entries.
  static const String _kRoute = 'gray.route';
  static const String _kCachedTarget = 'gray.target.value';
  static const String _kCachedTargetTtl = 'gray.target.ttl';
  static const String _kPushCooldown = 'gray.push.cooldown';
  static const String _kPushConsent = 'gray.push.consent';
  static const String _kPushOneShot = 'gray.push.oneshot';

  late SharedPreferences _prefs;
  final FlutterSecureStorage _vault = const FlutterSecureStorage();

  Future<void> bootstrap() async {
    _prefs = await SharedPreferences.getInstance();
  }

  LaunchRoute readRoute() => LaunchRoute.decode(_prefs.getString(_kRoute));

  Future<void> writeRoute(LaunchRoute route) async {
    await _prefs.setString(_kRoute, route.storageId());
  }

  Future<String?> readCachedTarget() async {
    try {
      return await _vault.read(key: _kCachedTarget);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeCachedTarget(String url) async {
    try {
      await _vault.write(key: _kCachedTarget, value: url);
    } catch (_) {}
  }

  int? _readTtl() => _prefs.getInt(_kCachedTargetTtl);

  Future<void> writeCachedTtl(int epochSeconds) async {
    await _prefs.setInt(_kCachedTargetTtl, epochSeconds);
  }

  bool isCachedTargetExpired() {
    final ttl = _readTtl();
    if (ttl == null) return true;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= ttl;
  }

  bool readPushConsent() => _prefs.getBool(_kPushConsent) ?? false;

  Future<void> writePushConsent(bool allowed) async {
    await _prefs.setBool(_kPushConsent, allowed);
  }

  int? readPushCooldownUntil() => _prefs.getInt(_kPushCooldown);

  Future<void> writePushCooldownUntil(int epochSeconds) async {
    await _prefs.setInt(_kPushCooldown, epochSeconds);
  }

  bool needsPushPrompt() {
    if (readPushConsent()) return false;
    final until = readPushCooldownUntil();
    if (until == null) return true;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= until;
  }

  Future<void> stashOneShotPush(String url) async {
    if (url.isEmpty) return;
    try {
      await _vault.write(key: _kPushOneShot, value: url);
    } catch (_) {}
  }

  Future<String?> consumeOneShotPush() async {
    try {
      final value = await _vault.read(key: _kPushOneShot);
      if (value != null) {
        await _vault.delete(key: _kPushOneShot);
      }
      return value;
    } catch (_) {
      return null;
    }
  }
}
