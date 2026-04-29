import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';

/// Tiny wrapper around `connectivity_plus` that performs an actual DNS lookup
/// before reporting that the device is online. Without the lookup we get
/// false positives on captive portals or stale connectivity events.
class NetworkRadar {
  final Connectivity _probe = Connectivity();

  Future<bool> isReachable() async {
    try {
      final results = await _probe.checkConnectivity();
      final hasInterface =
          results.any((s) => s != ConnectivityResult.none);
      if (!hasInterface) return false;
    } catch (_) {
      return false;
    }

    try {
      final lookup = await InternetAddress.lookup('cloudflare.com')
          .timeout(const Duration(seconds: 4));
      if (lookup.isEmpty) return false;
      return lookup.first.rawAddress.isNotEmpty;
    } on SocketException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Stream<List<ConnectivityResult>> watch() => _probe.onConnectivityChanged;
}
