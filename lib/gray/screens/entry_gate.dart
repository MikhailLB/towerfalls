import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../screens/loading_screen.dart';
import '../../screens/main_menu_screen.dart';
import '../models/launch_route.dart';
import '../services/install_signal_client.dart';
import '../services/native_push_bridge.dart';
import '../services/network_radar.dart';
import '../services/pulse_dispatch.dart';
import '../services/remote_gate_client.dart';
import '../services/runtime_cache.dart';
import 'browser_shell.dart';
import 'network_pause_screen.dart';
import 'notify_offer_screen.dart';

/// Entry point for the gray flow. Runs the boot pipeline (push bootstrap,
/// AppsFlyer warmup, gate dispatch, …) under the same loading splash that
/// the white-only path uses, so the user sees a single unified screen.
class EntryGate extends StatefulWidget {
  final RuntimeCache cache;
  final NetworkRadar radar;
  final InstallSignalClient install;
  final RemoteGateClient gate;
  final PulseDispatch pulse;

  const EntryGate({
    super.key,
    required this.cache,
    required this.radar,
    required this.install,
    required this.gate,
    required this.pulse,
  });

  @override
  State<EntryGate> createState() => _EntryGateState();
}

class _EntryGateState extends State<EntryGate> {
  late final Future<WidgetBuilder> _routeFuture;
  // Completes once the resolved underlay widget is fully on-screen. For the
  // BrowserShell case this fires on the first WebView onPageFinished; for any
  // other route it is completed eagerly in [_kickoff] so the loading splash
  // hands over without an extra wait.
  final Completer<void> _contentReady = Completer<void>();
  // Tells LoadingScreen whether the resolved widget must stay mounted
  // beneath the splash (web flow → preserve WebView state) or whether it
  // should be promoted to a top-level route via Navigator.pushReplacement
  // (every other route — MainMenu, NetworkPause, NotifyOffer — was mounted
  // that way originally and depends on having its own route to push from).
  final Completer<bool> _keepUnderlay = Completer<bool>();
  // Flipped to true by [_webBuilder] when the resolved route ends up being
  // BrowserShell. In that case [_kickoff] must NOT mark content ready
  // eagerly — BrowserShell.onFirstPaint owns the signal.
  bool _isWebFlow = false;

  void _markContentReady([String reason = 'eager']) {
    if (_contentReady.isCompleted) return;
    debugPrint('[TF.GRAY] contentReady: $reason');
    _contentReady.complete();
  }

  @override
  void initState() {
    super.initState();
    _routeFuture = _kickoff();
  }

  @override
  void dispose() {
    widget.pulse.onTokenRotated = null;
    super.dispose();
  }

  // Hard ceiling for the entire gray bootstrap. If we exceed this the loading
  // screen still hands over to the arcade flow so the user can play the game
  // even when AppsFlyer / FCM / the gateway misbehave on the device.
  // Tightened from 35s to 20s — every component below has its own timeout
  // (pulse=6s, conversion=7s, dispatch=8s) so the worst legitimate cold
  // start finishes well under 20s. Anything past that is a real hang.
  static const Duration _kickoffBudget = Duration(seconds: 20);

  Future<WidgetBuilder> _kickoff() async {
    final swMain = Stopwatch()..start();
    debugPrint('[TF.GRAY] kickoff: enter (budget=${_kickoffBudget.inSeconds}s)');
    WidgetBuilder builder;
    try {
      builder = await _runKickoff().timeout(_kickoffBudget);
      debugPrint(
          '[TF.GRAY] kickoff: done in ${swMain.elapsedMilliseconds}ms');
    } on TimeoutException {
      debugPrint(
          '[TF.GRAY] kickoff: TIMEOUT after ${swMain.elapsedMilliseconds}ms — fallback to arcade');
      builder = (_) => const MainMenuScreen();
    } catch (err, st) {
      debugPrint(
          '[TF.GRAY] kickoff: ERROR after ${swMain.elapsedMilliseconds}ms: $err\n$st');
      builder = (_) => const MainMenuScreen();
    }
    // Non-web routes don't have their own readiness signal — fire the
    // contentReady gate immediately so the loading splash hands over as soon
    // as the progress bar finishes. Web routes set [_isWebFlow] in
    // [_webBuilder] and own the signal via BrowserShell.onFirstPaint.
    if (!_isWebFlow) {
      _markContentReady('non-web route');
    }
    if (!_keepUnderlay.isCompleted) {
      _keepUnderlay.complete(_isWebFlow);
    }
    return builder;
  }

  Future<WidgetBuilder> _runKickoff() async {
    widget.pulse.onTokenRotated = _onTokenRotated;

    // STEP 1 — HIGHEST PRIORITY: native cold-start URL.
    //
    // SceneDelegate captures the URL from the killed-app push tap BEFORE any
    // Dart code runs (Firebase swizzle misses these because scene-based apps
    // don't put the notification into launchOptions[remoteNotification]).
    // We read it the very first thing so it overrides every other path —
    // cached route, AppsFlyer offers, gateway dispatch — and the user is
    // routed to the push URL no matter what state the gray flow is in.
    final swNative = Stopwatch()..start();
    final nativeColdStartUrl = await NativePushBridge.consumeColdStartUrl();
    debugPrint(
        '[TF.GRAY] native cold-start probe done in ${swNative.elapsedMilliseconds}ms,'
        ' url=${nativeColdStartUrl ?? 'null'}');

    // Pulse.bootstrap is now pre-fired in main() to overlap with first build
    // + splash video init. Calling it here just returns the cached in-flight
    // future, so the timeout below is the deadline for whatever progress is
    // still pending by the time _runKickoff runs.
    final swPulse = Stopwatch()..start();
    final pulseFuture = widget.pulse
        .bootstrap()
        .timeout(const Duration(seconds: 6))
        .then((_) {
          debugPrint(
              '[TF.GRAY] pulse.bootstrap done in ${swPulse.elapsedMilliseconds}ms,'
              ' fcm=${widget.pulse.token == null ? 'null' : 'present'}');
        })
        .catchError((err) {
          debugPrint(
              '[TF.GRAY] pulse.bootstrap failed in ${swPulse.elapsedMilliseconds}ms: $err');
        });

    // If we have a native cold-start URL, take the express lane: skip the
    // full attribution + gateway pipeline, route the user straight to the
    // push destination, and persist that the user is now on the web route
    // so subsequent launches go through the fast path.
    if (nativeColdStartUrl != null && nativeColdStartUrl.isNotEmpty) {
      debugPrint(
          '[TF.GRAY] EXPRESS-LANE → BrowserShell @ $nativeColdStartUrl');
      await widget.cache.writeRoute(LaunchRoute.web);
      // Clear the one-shot push stash: the background FCM handler may have
      // written the same URL there before the user tapped. If we leave it,
      // BrowserShell._drainPushStash() will call loadRequest() a second time
      // right after initState, interrupting the first load and causing the
      // white/blue blank-screen flash.
      await widget.cache.consumeOneShotPush();
      // Background install / token dispatch so the backend still gets the
      // signal — never blocking the user behind it.
      unawaited(_dispatchExpressLane(pulseFuture));
      // Go DIRECTLY to BrowserShell — never show NotifyOfferScreen when the
      // user arrived by tapping a push notification. The push prompt check
      // in _webBuilder() calls shouldOfferConsent() which on iOS TestFlight
      // returns true (provisional-auth leaves status=notDetermined), causing
      // the dark opt-in screen to block navigation to the push URL.
      return _directBrowserShell(nativeColdStartUrl);
    }

    final route = widget.cache.readRoute();
    debugPrint('[TF.GRAY] cached route=$route');
    switch (route) {
      case LaunchRoute.web:
        return _runReturningWebFlow(pulseFuture);
      case LaunchRoute.arcade:
        debugPrint(
            '[TF.GRAY] route=arcade, but gray is enabled → re-check config');
        return _runFirstLaunchFlow(pulseFuture);
      case LaunchRoute.pristine:
        return _runFirstLaunchFlow(pulseFuture);
    }
  }

  /// Best-effort backend ping after we've already routed the user via a
  /// native cold-start URL. Warms up AppsFlyer, composes a payload and
  /// dispatches — failures are logged and swallowed.
  Future<void> _dispatchExpressLane(Future<void> pulseFuture) async {
    try {
      await widget.install.warmup();
      await Future.wait([
        widget.install.awaitConversion(timeout: const Duration(seconds: 6)),
        widget.install.awaitDeepLink(),
        pulseFuture,
      ]);
      final body = await widget.install.composePayload(
        locale: Platform.localeName.replaceAll('-', '_'),
        pushToken: widget.pulse.token,
      );
      final reply = await widget.gate.dispatch(body);
      debugPrint(
          '[TF.GRAY] express-lane dispatch granted=${reply.granted}'
          ' dest=${reply.destination ?? 'null'}');
    } catch (err) {
      debugPrint('[TF.GRAY] express-lane dispatch failed: $err');
    }
  }

  Future<WidgetBuilder> _runFirstLaunchFlow(
    Future<void> pulseFuture,
  ) async {
    debugPrint('[TF.GRAY] flow=first-launch');
    final online = await widget.radar.isReachable();
    debugPrint('[TF.GRAY] network reachable=$online');
    if (!online) {
      debugPrint('[TF.GRAY] offline → NetworkPauseScreen');
      return _offlineBuilder(returnAsFirstLaunch: true);
    }

    // Start AppsFlyer warmup + conversion wait in the background so it
    // overlaps with pulse.bootstrap (running concurrently from _runKickoff).
    final swWarm = Stopwatch()..start();
    final installFuture = (() async {
      await widget.install.warmup();
      debugPrint(
          '[TF.GRAY] install.warmup done in ${swWarm.elapsedMilliseconds}ms');
      await Future.wait([
        widget.install.awaitConversion(timeout: const Duration(seconds: 7)),
        widget.install.awaitDeepLink(),
      ]);
      debugPrint(
          '[TF.GRAY] install awaits done in ${swWarm.elapsedMilliseconds}ms');
    })();

    // Wait briefly for the cold-start capture (fast in-memory read). NSE +
    // SceneDelegate already wrote any cold-start URL to UserDefaults BEFORE
    // any Dart code ran, so the NativePushBridge probe in _runKickoff has
    // already consumed that path. This gate covers the residual
    // `getInitialMessage()` path for FCM-route pushes that bypass our
    // SceneDelegate (rare, but still possible in mixed payloads). 2s is
    // enough — anything slower is just locking the splash.
    final swCold = Stopwatch()..start();
    await widget.pulse.coldStartReady.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        debugPrint(
            '[TF.GRAY] coldStartReady timeout after ${swCold.elapsedMilliseconds}ms — proceeding without push');
      },
    );
    debugPrint(
        '[TF.GRAY] coldStartReady resolved in ${swCold.elapsedMilliseconds}ms');

    final earlyPush = await widget.cache.consumeOneShotPush();
    if (earlyPush != null) {
      debugPrint(
          '[TF.GRAY] cold-start push pending → BrowserShell @ $earlyPush');
      // Persist the route now so subsequent launches go through the
      // returning-web flow (fast path) instead of paying the full
      // AppsFlyer cost on every launch.
      await widget.cache.writeRoute(LaunchRoute.web);
      // Fire the gateway dispatch in the background so the backend still
      // tracks the install — but never block the user behind it.
      unawaited(_dispatchInBackground(installFuture, pulseFuture));
      // Use the direct builder — no NotifyOfferScreen interruption for
      // push-originated navigations (same rationale as the express lane).
      return _directBrowserShell(earlyPush);
    }

    // No push — wait for the rest of the pipeline (token, conversion data).
    await Future.wait([pulseFuture, installFuture]);

    final body = await widget.install.composePayload(
      locale: Platform.localeName.replaceAll('-', '_'),
      pushToken: widget.pulse.token,
    );
    debugPrint('[TF.GRAY] payload keys=${body.keys.toList()}');

    final swDispatch = Stopwatch()..start();
    final reply = await widget.gate.dispatch(body);
    debugPrint(
        '[TF.GRAY] gate.dispatch done in ${swDispatch.elapsedMilliseconds}ms'
        ' granted=${reply.granted} dest=${reply.destination ?? 'null'}'
        ' note=${reply.note ?? '-'}');

    if (reply.granted && reply.destination != null) {
      await widget.cache.writeRoute(LaunchRoute.web);
      debugPrint(
          '[TF.GRAY] decision=WEB → BrowserShell @ ${reply.destination}');
      return _webBuilder(reply.destination!);
    }
    await widget.cache.writeRoute(LaunchRoute.arcade);
    debugPrint('[TF.GRAY] decision=ARCADE → MainMenuScreen');
    return (_) => const MainMenuScreen();
  }

  /// Best-effort install signal sent in the background after the user has
  /// already been routed via a cold-start push URL. Awaits both the install
  /// pipeline (for conversion data) and the pulse pipeline (for the FCM
  /// token) so the backend gets the full payload — but never blocks the UI.
  Future<void> _dispatchInBackground(
    Future<void> installFuture,
    Future<void> pulseFuture,
  ) async {
    try {
      await Future.wait([installFuture, pulseFuture]);
      final body = await widget.install.composePayload(
        locale: Platform.localeName.replaceAll('-', '_'),
        pushToken: widget.pulse.token,
      );
      final reply = await widget.gate.dispatch(body);
      debugPrint(
          '[TF.GRAY] background dispatch granted=${reply.granted} '
          'dest=${reply.destination ?? 'null'}');
    } catch (err) {
      debugPrint('[TF.GRAY] background dispatch failed: $err');
    }
  }

  Future<WidgetBuilder> _runReturningWebFlow(
    Future<void> pulseFuture,
  ) async {
    debugPrint('[TF.GRAY] flow=returning-web');
    final online = await widget.radar.isReachable();
    debugPrint('[TF.GRAY] network reachable=$online');
    if (!online) {
      debugPrint('[TF.GRAY] offline → NetworkPauseScreen');
      return _offlineBuilder(returnAsFirstLaunch: false);
    }

    // Start AppsFlyer warmup + conversion wait in parallel with pulse.
    final swWarm = Stopwatch()..start();
    final installFuture = (() async {
      await widget.install.warmup();
      debugPrint(
          '[TF.GRAY] install.warmup done in ${swWarm.elapsedMilliseconds}ms');
      await Future.wait([
        widget.install.awaitConversion(timeout: const Duration(seconds: 5)),
        widget.install.awaitDeepLink(),
      ]);
      debugPrint(
          '[TF.GRAY] install awaits done in ${swWarm.elapsedMilliseconds}ms');
    })();

    // Brief cold-start fallback gate (see _runFirstLaunchFlow rationale).
    final swCold = Stopwatch()..start();
    await widget.pulse.coldStartReady.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        debugPrint(
            '[TF.GRAY] coldStartReady timeout after ${swCold.elapsedMilliseconds}ms — proceeding without push');
      },
    );
    debugPrint(
        '[TF.GRAY] coldStartReady resolved in ${swCold.elapsedMilliseconds}ms');

    final oneShot = await widget.cache.consumeOneShotPush();
    if (oneShot != null) {
      debugPrint('[TF.GRAY] one-shot push pending → BrowserShell @ $oneShot');
      unawaited(_dispatchInBackground(installFuture, pulseFuture));
      // Direct builder — skip NotifyOfferScreen for push-originated flows.
      return _directBrowserShell(oneShot);
    }

    final cached = await widget.cache.readCachedTarget();
    debugPrint('[TF.GRAY] cached target=${cached ?? 'null'}');

    // No push — wait for the rest of the pipeline.
    await Future.wait([pulseFuture, installFuture]);

    final body = await widget.install.composePayload(
      locale: Platform.localeName.replaceAll('-', '_'),
      pushToken: widget.pulse.token,
    );

    final swDispatch = Stopwatch()..start();
    final reply = await widget.gate.dispatch(body);
    debugPrint(
        '[TF.GRAY] gate.dispatch done in ${swDispatch.elapsedMilliseconds}ms'
        ' granted=${reply.granted} dest=${reply.destination ?? 'null'}'
        ' note=${reply.note ?? '-'}');

    if (reply.granted && reply.destination != null) {
      debugPrint('[TF.GRAY] decision=WEB → BrowserShell @ ${reply.destination}');
      return _webBuilder(reply.destination!);
    }
    if (cached != null) {
      debugPrint('[TF.GRAY] decision=CACHED-WEB → BrowserShell @ $cached');
      return _webBuilder(cached);
    }
    debugPrint('[TF.GRAY] decision=NO-DEST → NetworkPauseScreen');
    return _offlineBuilder(returnAsFirstLaunch: false);
  }

  /// Builds a BrowserShell route directly, bypassing the [NotifyOfferScreen]
  /// push-opt-in gate. Use this for any path where the user explicitly tapped a
  /// push notification — they've already proved they want the URL and the OS
  /// push status check would incorrectly show the prompt on iOS TestFlight
  /// (provisional auth leaves status=notDetermined even when pushes work).
  WidgetBuilder _directBrowserShell(String url) {
    _isWebFlow = true;
    return (_) => BrowserShell(
          destination: url,
          cache: widget.cache,
          pulse: widget.pulse,
          radar: widget.radar,
          onFirstPaint: () => _markContentReady('webview first paint'),
        );
  }

  Future<WidgetBuilder> _webBuilder(String url) async {
    // Two gates have to be passed before we offer the in-app push prompt:
    //   1. App-side cooldown (3 days after a previous "Skip" / decline).
    //   2. The OS still allows us to ASK (notDetermined). On iOS, once the
    //      user has tapped "Don't Allow", requestPermission() can never show
    //      the system sheet again, so re-showing our offer screen is just
    //      noise — and tapping "Accept" on it would silently no-op.
    if (widget.cache.needsPushPrompt()) {
      final canAsk = await widget.pulse.shouldOfferConsent();
      debugPrint('[TF.GRAY] push offer gate: canAsk=$canAsk');
      if (canAsk) {
        // NotifyOfferScreen is interactive — content "readiness" is the moment
        // it appears, no extra wait needed.
        return (_) => NotifyOfferScreen(
              cache: widget.cache,
              pulse: widget.pulse,
              radar: widget.radar,
              destination: url,
              onPushTokenReady: _sendPushTokenUpdate,
            );
      }
    }
    // BrowserShell signals readiness via [onFirstPaint] so the loading splash
    // stays up until the WebView has actually rendered the first page.
    _isWebFlow = true;
    return (_) => BrowserShell(
          destination: url,
          cache: widget.cache,
          pulse: widget.pulse,
          radar: widget.radar,
          onFirstPaint: () => _markContentReady('webview first paint'),
        );
  }

  WidgetBuilder _offlineBuilder({required bool returnAsFirstLaunch}) {
    return (_) => NetworkPauseScreen(
          radar: widget.radar,
          retryBuilder: (_) => EntryGate(
            cache: widget.cache,
            radar: widget.radar,
            install: widget.install,
            gate: widget.gate,
            pulse: widget.pulse,
          ),
        );
  }

  void _onTokenRotated(String fresh) async {
    _sendPushTokenUpdate(fresh);
  }

  Future<void> _sendPushTokenUpdate(String fresh) async {
    final body = await widget.install.composePayload(
      locale: Platform.localeName.replaceAll('-', '_'),
      pushToken: fresh,
    );
    await widget.gate.dispatch(body);
  }

  @override
  Widget build(BuildContext context) {
    return LoadingScreen(
      routeFuture: _routeFuture,
      contentReady: _contentReady.future,
      keepAsUnderlay: _keepUnderlay.future,
    );
  }
}
