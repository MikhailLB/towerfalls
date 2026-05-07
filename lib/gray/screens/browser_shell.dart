import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../services/network_radar.dart';
import '../services/pulse_dispatch.dart';
import '../services/runtime_cache.dart';
import '../services/secure_http.dart';
import 'network_pause_screen.dart';

class BrowserShell extends StatefulWidget {
  final String destination;
  final RuntimeCache cache;
  final PulseDispatch pulse;
  final NetworkRadar radar;
  // Fires once, on the first successful onPageFinished. Used by EntryGate to
  // hold the loading splash up until the WebView has actually rendered the
  // first page, so the user never sees the "100% bar → black screen" gap.
  final VoidCallback? onFirstPaint;

  const BrowserShell({
    super.key,
    required this.destination,
    required this.cache,
    required this.pulse,
    required this.radar,
    this.onFirstPaint,
  });

  @override
  State<BrowserShell> createState() => _BrowserShellState();
}

class _BrowserShellState extends State<BrowserShell>
    with WidgetsBindingObserver {
  late final WebViewController _wv;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  bool _routedOffline = false;
  String? _lastMainFrame;
  int _redirectRetries = 0;

  Widget? _fullscreen;
  void Function()? _hideFullscreen;
  bool _firstPaintFired = false;

  StreamSubscription<RemoteMessage>? _pushSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lockOrientations();
    _applyFullscreen();

    // Platform-specific creation params for WebView. On iOS these MUST be
    // passed at construction time — setters have no effect after init:
    //   allowsInlineMediaPlayback: true  → <video> doesn't force fullscreen
    //   mediaTypesRequiringUserAction: {} → muted autoplay works without tap
    late final PlatformWebViewControllerCreationParams params;
    if (Platform.isIOS) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else if (Platform.isAndroid) {
      params = AndroidWebViewControllerCreationParams();
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    _wv = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(secureHttp.userAgent)
      ..setBackgroundColor(Colors.black)
      ..enableZoom(false)
      ..setNavigationDelegate(_delegate());

    _setupPlatform();
    _wv.loadRequest(Uri.parse(widget.destination));

    widget.pulse.onPushDestination = (url) {
      if (!mounted) return;
      try {
        final uri = Uri.parse(url);
        if (uri.hasScheme) _wv.loadRequest(uri);
      } catch (_) {}
    };

    _connSub = widget.radar.watch().listen((statuses) {
      if (statuses.every((s) => s == ConnectivityResult.none)) {
        _maybeRouteOffline();
      }
    });

    // Direct listener on onMessageOpenedApp. This catches the case where the
    // user taps a notification while the browser is already visible — the
    // PulseDispatch callback chain has an inherent race (callback may be null
    // during the brief window between app resume and initState completing).
    _pushSub = FirebaseMessaging.onMessageOpenedApp.listen((msg) {
      final url = msg.data['url'] as String?;
      debugPrint('[TF.WV] onMessageOpenedApp url=${url ?? 'null'}');
      if (url != null && url.isNotEmpty && mounted) {
        try {
          final uri = Uri.parse(url);
          if (uri.hasScheme) _wv.loadRequest(uri);
        } catch (_) {}
      }
    });

    // On first mount check if a push URL was stashed before BrowserShell
    // was ready (e.g. notification tapped during app launch or while the
    // loading splash was still on screen).
    WidgetsBinding.instance.addPostFrameCallback((_) => _drainPushStash());
  }

  Future<void> _drainPushStash() async {
    final url = await widget.cache.consumeOneShotPush();
    if (url != null && url.isNotEmpty && mounted) {
      debugPrint('[TF.WV] drainPushStash url=$url');
      try {
        final uri = Uri.parse(url);
        if (uri.hasScheme) _wv.loadRequest(uri);
      } catch (_) {}
    }
  }

  void _lockOrientations() {
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  void _applyFullscreen() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _applyFullscreen();
      // When the app comes back to foreground (user tapped a push notification
      // while the browser was visible), onMessageOpenedApp fires and stashes
      // the URL via _dispatchUrl. If the live onPushDestination callback
      // already consumed it nothing is in the stash; if there's a race
      // (callback set a frame late) we catch it here.
      _drainPushStash();
    }
  }

  NavigationDelegate _delegate() {
    return NavigationDelegate(
      onPageStarted: (_) {},
      onPageFinished: (url) {
        _redirectRetries = 0;
        _injectSafeAreaShim();
        _injectKeyboardScroll();
        _injectMediaAutoplay();
        _injectCameraBlocker();
        _injectInputFontSize();
        if (!_firstPaintFired) {
          _firstPaintFired = true;
          // Delay the "content ready" signal by one short frame so the SPA
          // has time to mount its first component tree after the HTML document
          // has loaded. Without this the loading splash fades too early and
          // the user sees the website's blue CSS background while JavaScript
          // is still rendering the app shell.
          Future.delayed(const Duration(milliseconds: 700), () {
            try {
              widget.onFirstPaint?.call();
            } catch (_) {}
          });
        }
      },
      onWebResourceError: (err) {
        if (err.isForMainFrame != true) return;
        final desc = err.description.toLowerCase();
        final loop = desc.contains('too_many_redirects') ||
            desc.contains('too many redirects') ||
            err.errorCode == -1007 ||
            err.errorCode == -9;
        if (loop && _lastMainFrame != null && _redirectRetries < 3) {
          _redirectRetries++;
          _wv.loadRequest(Uri.parse(_lastMainFrame!));
          return;
        }
        _maybeRouteOffline();
      },
      onHttpError: (_) {},
      onNavigationRequest: (req) {
        final uri = Uri.tryParse(req.url);
        if (uri == null) return NavigationDecision.prevent;
        final scheme = uri.scheme;
        final inApp = scheme == 'http' ||
            scheme == 'https' ||
            scheme == 'about' ||
            scheme == 'data' ||
            scheme == 'blob';
        if (inApp) {
          if (req.isMainFrame) _lastMainFrame = req.url;
          return NavigationDecision.navigate;
        }
        _launchExternal(uri);
        return NavigationDecision.prevent;
      },
    );
  }

  void _setupPlatform() {
    if (Platform.isIOS && _wv.platform is WebKitWebViewController) {
      (_wv.platform as WebKitWebViewController)
          .setAllowsBackForwardNavigationGestures(true);
    }
    if (Platform.isAndroid && _wv.platform is AndroidWebViewController) {
      final android = _wv.platform as AndroidWebViewController;
      android.setMediaPlaybackRequiresUserGesture(false);
      android.setOnShowFileSelector(_pickFiles);
      android.setOnPlatformPermissionRequest((req) {
        final drmOnly = req.types.every(
          (t) =>
              t == AndroidWebViewPermissionResourceType.protectedMediaId ||
              t == AndroidWebViewPermissionResourceType.midiSysex,
        );
        drmOnly ? req.grant() : req.deny();
      });
      android.setCustomWidgetCallbacks(
        onShowCustomWidget: (w, hide) {
          _hideFullscreen = hide;
          if (mounted) setState(() => _fullscreen = w);
        },
        onHideCustomWidget: () {
          _hideFullscreen = null;
          if (mounted) setState(() => _fullscreen = null);
        },
      );
      final cookies = AndroidWebViewCookieManager(
        AndroidWebViewCookieManagerCreationParams
            .fromPlatformWebViewCookieManagerCreationParams(
          const PlatformWebViewCookieManagerCreationParams(),
        ),
      );
      cookies.setAcceptThirdPartyCookies(android, true);
    }
  }

  Future<List<String>> _pickFiles(FileSelectorParams p) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: p.mode == FileSelectorMode.openMultiple,
        type: FileType.any,
      );
      if (result == null) return const [];
      return result.files
          .where((f) => f.path != null)
          .map((f) => Uri.file(f.path!).toString())
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _maybeRouteOffline() async {
    if (_routedOffline) return;
    final ok = await widget.radar.isReachable();
    if (ok || !mounted) return;
    _routedOffline = true;
    final current = await _wv.currentUrl() ?? widget.destination;
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => NetworkPauseScreen(
          radar: widget.radar,
          retryBuilder: (_) => BrowserShell(
            destination: current,
            cache: widget.cache,
            pulse: widget.pulse,
            radar: widget.radar,
          ),
        ),
      ),
    );
  }

  void _launchExternal(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  void _injectKeyboardScroll() {
    _wv.runJavaScript(r'''
(function(){
  if (window.__tfKbFix) return;
  window.__tfKbFix = true;
  function inputLike(n){ return n && (n.tagName==='INPUT' || n.tagName==='TEXTAREA' || n.isContentEditable); }
  function focusRoll(){
    var el = document.activeElement;
    if (!inputLike(el)) return;
    var vp = window.visualViewport;
    if (vp){
      var r = el.getBoundingClientRect();
      if (r.bottom > vp.offsetTop + vp.height - 20 || r.top < vp.offsetTop){
        el.scrollIntoView({ behavior:'smooth', block:'center' });
      }
    } else {
      el.scrollIntoView({ behavior:'smooth', block:'center' });
    }
  }
  document.addEventListener('focusin', function(e){
    if (inputLike(e.target)){
      setTimeout(focusRoll,250);
      setTimeout(focusRoll,500);
      setTimeout(focusRoll,800);
    }
  });
  if (window.visualViewport){
    var prev = window.visualViewport.height;
    window.visualViewport.addEventListener('resize', function(){
      var h = window.visualViewport.height;
      if (h < prev){ setTimeout(focusRoll,80); setTimeout(focusRoll,300); }
      prev = h;
    });
  }
})();
''');
  }

  void _injectCameraBlocker() {
    _wv.runJavaScript(r'''
(function(){
  if (window.__tfNoCam) return;
  window.__tfNoCam = true;
  function strip(el){
    if (!el || el.tagName !== 'INPUT') return;
    if ((el.type || '').toLowerCase() !== 'file') return;
    if (el.hasAttribute('capture')) el.removeAttribute('capture');
    var accept = (el.getAttribute('accept') || '').toLowerCase();
    if (accept.indexOf('video') !== -1 || accept.indexOf('audio') !== -1){
      el.setAttribute('accept', 'image/*');
    }
  }
  function sweep(){
    var nodes = document.querySelectorAll('input[type=file]');
    for (var i = 0; i < nodes.length; i++) strip(nodes[i]);
  }
  sweep();
  var mo = new MutationObserver(function(muts){
    for (var i = 0; i < muts.length; i++){
      var m = muts[i];
      if (m.type === 'attributes'){ strip(m.target); continue; }
      for (var j = 0; j < m.addedNodes.length; j++){
        var n = m.addedNodes[j];
        if (!n || n.nodeType !== 1) continue;
        strip(n);
        if (n.querySelectorAll){
          var sub = n.querySelectorAll('input[type=file]');
          for (var k = 0; k < sub.length; k++) strip(sub[k]);
        }
      }
    }
  });
  mo.observe(document.documentElement, {
    childList: true, subtree: true,
    attributes: true, attributeFilter: ['capture','accept','type']
  });
  try {
    var blocked = function(){ return Promise.reject(new DOMException('NotAllowedError')); };
    if (navigator.mediaDevices){
      navigator.mediaDevices.getUserMedia = blocked;
      navigator.mediaDevices.getDisplayMedia = blocked;
    } else {
      Object.defineProperty(navigator, 'mediaDevices', {
        configurable: true, value: { getUserMedia: blocked, getDisplayMedia: blocked }
      });
    }
    if (navigator.getUserMedia) navigator.getUserMedia = function(_, __, err){
      try { err && err(new Error('NotAllowedError')); } catch(_){}
    };
  } catch(_){}
})();
''');
  }

  void _injectSafeAreaShim() {
    _wv.runJavaScript(r'''
(function(){
  if (window.__tfSaShim) return;
  window.__tfSaShim = true;
  var ID = '__tfSaShim';
  var CSS = ':root{'
    + '--safe-area-inset-top:0px!important;'
    + '--safe-area-inset-right:0px!important;'
    + '--safe-area-inset-bottom:0px!important;'
    + '--safe-area-inset-left:0px!important;'
    + '--sat:0px!important;--sar:0px!important;'
    + '--sab:0px!important;--sal:0px!important;'
    + '--safe-top:0px!important;--safe-right:0px!important;'
    + '--safe-bottom:0px!important;--safe-left:0px!important;'
    + '}'
    + 'html,body,#__nuxt,#__layout,#app,#root,.gameview-mobile-header{'
    + 'padding-top:0!important;padding-left:0!important;padding-right:0!important;margin-top:0!important;'
    + '}';
  function apply(){
    var head = document.head || document.documentElement;
    if (!head) return;
    var vp = document.querySelector('meta[name="viewport"]');
    if (vp && !/viewport-fit\s*=\s*contain/i.test(vp.getAttribute('content') || '')){
      var c = (vp.getAttribute('content') || '').replace(/,?\s*viewport-fit\s*=\s*\w+/ig,'').trim();
      vp.setAttribute('content', c + (c ? ', ' : '') + 'viewport-fit=contain');
    }
    var s = document.getElementById(ID);
    if (!s){ s = document.createElement('style'); s.id = ID; head.appendChild(s); }
    if (s.textContent !== CSS) s.textContent = CSS;
    if (head.lastElementChild !== s) head.appendChild(s);
  }
  apply();
  ['pushState','replaceState'].forEach(function(name){
    var orig = history[name];
    history[name] = function(){
      var r = orig.apply(this, arguments);
      setTimeout(apply,80); setTimeout(apply,400);
      return r;
    };
  });
  window.addEventListener('popstate', function(){ setTimeout(apply,80); });
  setInterval(apply, 2500);
})();
''');
  }

  void _injectMediaAutoplay() {
    _wv.runJavaScript(r'''
(function(){
  if (window.__tfVideoAuto) return;
  window.__tfVideoAuto = true;
  function prep(v){
    try {
      v.setAttribute('playsinline',''); v.setAttribute('webkit-playsinline','');
      v.playsInline=true; v.muted=true; v.defaultMuted=true; v.autoplay=true;
      var p=v.play&&v.play(); if(p&&p.catch)p.catch(function(){});
    } catch(_){}
  }
  function sweep(root){
    try { var l=(root||document).querySelectorAll('video'); for(var i=0;i<l.length;i++)prep(l[i]); }catch(_){}
  }
  sweep(document);
  document.addEventListener('touchend',function(){sweep(document);},{passive:true});
  var mo=new MutationObserver(function(recs){
    for(var i=0;i<recs.length;i++){
      var nodes=recs[i].addedNodes||[];
      for(var j=0;j<nodes.length;j++){
        var n=nodes[j]; if(!n||n.nodeType!==1)continue;
        if(n.tagName==='VIDEO')prep(n); sweep(n);
      }
    }
  });
  mo.observe(document.documentElement,{childList:true,subtree:true});
  setInterval(function(){sweep(document);},1500);
})();
''');
  }

  // Prevent iOS WKWebView auto-zoom on input focus by forcing input font-size
  // to 16px via a one-shot CSS injection. iOS only zooms when the computed
  // font-size is less than 16px, so this disables the behaviour without
  // touching <meta viewport> (which previously caused crashes when patched
  // dynamically while the page was handling focus events).
  void _injectInputFontSize() {
    if (!Platform.isIOS) return;
    _wv.runJavaScript(r'''
(function(){
  if (window.__tfInputFs) return;
  window.__tfInputFs = true;
  try {
    var s = document.createElement('style');
    s.id = '__tfInputFs';
    s.textContent =
      'input,textarea,select,[contenteditable=true]{font-size:16px!important;}';
    (document.head || document.documentElement).appendChild(s);
  } catch(_){}
})();
''');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connSub?.cancel();
    _pushSub?.cancel();
    widget.pulse.onPushDestination = null;
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    _lockOrientations();
    super.dispose();
  }

  Future<bool> _handleBack() async {
    if (_fullscreen != null) {
      _hideFullscreen?.call();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.of(context).viewPadding;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _handleBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: EdgeInsets.only(
                top: safe.top,
                bottom: safe.bottom,
                left: safe.left,
                right: safe.right,
              ),
              child: WebViewWidget(controller: _wv),
            ),
            if (_fullscreen != null) Positioned.fill(child: _fullscreen!),
          ],
        ),
      ),
    );
  }
}

