import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
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

/// In-app browser used when the gateway returns a destination URL. Keeps the
/// session sticky to the first landed page and routes external schemes via
/// the OS so the experience matches a real mobile browser.
class BrowserShell extends StatefulWidget {
  final String destination;
  final RuntimeCache cache;
  final PulseDispatch pulse;
  final NetworkRadar radar;

  const BrowserShell({
    super.key,
    required this.destination,
    required this.cache,
    required this.pulse,
    required this.radar,
  });

  @override
  State<BrowserShell> createState() => _BrowserShellState();
}

class _BrowserShellState extends State<BrowserShell>
    with WidgetsBindingObserver {
  late final WebViewController _wv;
  bool _loading = true;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  bool _routedOffline = false;
  String? _lastMainFrame;
  int _redirectRetries = 0;
  String? _firstFinalUrl;

  Widget? _fullscreen;
  void Function()? _hideFullscreen;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applyOrientations();
    _showSystemBars();

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
      ..setNavigationDelegate(_buildDelegate());

    _attachPlatform();
    _attachWebKit();
    _wv.loadRequest(Uri.parse(widget.destination));

    widget.pulse.onPushDestination = (url) {
      if (!mounted) return;
      _wv.loadRequest(Uri.parse(url));
    };

    _connSub = widget.radar.watch().listen((statuses) {
      final allGone = statuses.every((s) => s == ConnectivityResult.none);
      if (allGone) _maybeRouteOffline();
    });
  }

  void _applyOrientations() {
    // Empty list delegates rotation to the Android activity. The activity is
    // marked as fullUser: it auto-rotates when the user enables auto-rotate
    // and lets Android show the native rotate suggestion when the setting is
    // disabled on devices that support that system feature.
    SystemChrome.setPreferredOrientations(const []);
  }

  void _showSystemBars() {
    // Keep system bars visible in the WebView. Android's native rotate
    // suggestion then appears in the navigation area instead of floating over
    // the web content and blocking controls.
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _showSystemBars();
  }

  NavigationDelegate _buildDelegate() {
    return NavigationDelegate(
      onPageStarted: (_) {
        if (mounted) setState(() => _loading = true);
      },
      onPageFinished: (url) {
        if (mounted) setState(() => _loading = false);
        _redirectRetries = 0;
        _firstFinalUrl ??= url;
        _injectKeyboardScroll();
        _injectSafeAreaPatch();
        _injectMediaAutoplayShim();
        if (Platform.isIOS) {
          _injectCameraShim();
          _injectInputZoomGuard();
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

  void _attachWebKit() {
    if (!Platform.isIOS) return;
    if (_wv.platform is! WebKitWebViewController) return;
    final webkit = _wv.platform as WebKitWebViewController;
    try {
      webkit.setAllowsBackForwardNavigationGestures(true);
    } catch (err) {
      if (kDebugMode) debugPrint('[BS] setAllowsBackForwardNavigationGestures: $err');
    }
  }

  void _attachPlatform() {
    if (!Platform.isAndroid) return;
    if (_wv.platform is! AndroidWebViewController) return;
    final android = _wv.platform as AndroidWebViewController;

    android.setMediaPlaybackRequiresUserGesture(false);
    android.setOnShowFileSelector(_pickFiles);

    android.setOnPlatformPermissionRequest(
      (PlatformWebViewPermissionRequest request) {
        final drmOnly = request.types.every(
          (t) =>
              t == AndroidWebViewPermissionResourceType.protectedMediaId ||
              t == AndroidWebViewPermissionResourceType.midiSysex,
        );
        if (drmOnly) {
          request.grant();
        } else {
          request.deny();
        }
      },
    );

    android.setCustomWidgetCallbacks(
      onShowCustomWidget: (Widget overlay, void Function() hideCallback) {
        _hideFullscreen = hideCallback;
        if (mounted) setState(() => _fullscreen = overlay);
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

  Future<List<String>> _pickFiles(FileSelectorParams params) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: params.mode == FileSelectorMode.openMultiple,
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
  if (window.__tfKbScroll) return;
  window.__tfKbScroll = true;
  var STYLE_ID = '__tfKbScrollStyle';
  function applyKbPadding(){
    var vp = window.visualViewport;
    var bottom = 0;
    if (vp){
      bottom = Math.max(0, window.innerHeight - (vp.height + vp.offsetTop));
    }
    document.documentElement.style.setProperty('--tf-keyboard-bottom', bottom + 'px');
    var st = document.getElementById(STYLE_ID);
    if (!st){
      st = document.createElement('style');
      st.id = STYLE_ID;
      st.textContent = 'html,body{scroll-padding-bottom:calc(var(--tf-keyboard-bottom,0px) + 96px)!important;}';
      (document.head || document.documentElement).appendChild(st);
    }
  }
  function isInput(n){
    return n && (n.tagName === 'INPUT' || n.tagName === 'TEXTAREA' || n.isContentEditable);
  }
  function pull(){
    applyKbPadding();
    var el = document.activeElement;
    if (!isInput(el)) return;
    var vp = window.visualViewport;
    if (vp){
      var rect = el.getBoundingClientRect();
      if (rect.bottom > vp.offsetTop + vp.height - 88 || rect.top < vp.offsetTop + 16){
        el.scrollIntoView({behavior:'smooth', block:'center'});
      }
    } else {
      el.scrollIntoView({behavior:'smooth', block:'center'});
    }
  }
  document.addEventListener('focusin', function(e){
    if (isInput(e.target)){
      setTimeout(pull, 220);
      setTimeout(pull, 480);
      setTimeout(pull, 820);
    }
  });
  if (window.visualViewport){
    var prev = window.visualViewport.height;
    window.visualViewport.addEventListener('resize', function(){
      var h = window.visualViewport.height;
      applyKbPadding();
      if (h < prev){ setTimeout(pull, 80); setTimeout(pull, 320); setTimeout(pull, 700); }
      prev = h;
    });
    window.visualViewport.addEventListener('scroll', applyKbPadding);
  }
  applyKbPadding();
})();
''');
  }

  // iOS WKWebView automatically zooms the page when the user focuses an
  // <input>/<textarea> with computed font-size < 16px (especially noticeable in
  // landscape, where the zoom often hides the keyboard or shifts content).
  // Two-pronged guard:
  //  * patch the viewport meta tag with maximum-scale=1.0 so iOS suppresses the
  //    focus zoom (honored on iOS 10+).
  //  * raise the form control font-size to 16px so the heuristic does not even
  //    trigger if some script later overrides the meta tag.
  void _injectInputZoomGuard() {
    _wv.runJavaScript(r'''
(function(){
  if (window.__tfNoZoom) return;
  window.__tfNoZoom = true;
  var STYLE_ID = '__tfNoZoomStyle';
  function patchViewport(){
    var meta = document.querySelector('meta[name="viewport"]');
    if (!meta){
      meta = document.createElement('meta');
      meta.setAttribute('name', 'viewport');
      meta.setAttribute('content',
        'width=device-width, initial-scale=1.0, maximum-scale=1.0, viewport-fit=cover');
      (document.head || document.documentElement).appendChild(meta);
      return;
    }
    var c = meta.getAttribute('content') || '';
    if (!/maximum-scale\s*=/i.test(c)){
      c = (c ? c + ', ' : '') + 'maximum-scale=1.0';
    } else {
      c = c.replace(/maximum-scale\s*=\s*[\d.]+/ig, 'maximum-scale=1.0');
    }
    if (!/initial-scale\s*=/i.test(c)){
      c = (c ? c + ', ' : '') + 'initial-scale=1.0';
    }
    meta.setAttribute('content', c);
  }
  function patchStyle(){
    var st = document.getElementById(STYLE_ID);
    if (st) return;
    st = document.createElement('style');
    st.id = STYLE_ID;
    st.textContent =
      'input,select,textarea{font-size:16px!important;-webkit-text-size-adjust:100%!important;}';
    (document.head || document.documentElement).appendChild(st);
  }
  patchViewport();
  patchStyle();
  var mo = new MutationObserver(function(){
    patchViewport();
    patchStyle();
  });
  try { mo.observe(document.documentElement, {childList:true, subtree:true}); } catch(_){}
})();
''');
  }

  void _injectMediaAutoplayShim() {
    _wv.runJavaScript(r'''
(function(){
  if (window.__tfVideoAuto) return;
  window.__tfVideoAuto = true;
  function prep(v){
    try {
      v.setAttribute('playsinline', '');
      v.setAttribute('webkit-playsinline', '');
      v.playsInline = true;
      v.muted = true;
      v.defaultMuted = true;
      v.autoplay = true;
      var p = v.play && v.play();
      if (p && p.catch) p.catch(function(){});
    } catch(_){}
  }
  function sweep(root){
    try {
      var list = (root || document).querySelectorAll('video');
      for (var i = 0; i < list.length; i++) prep(list[i]);
    } catch(_){}
  }
  sweep(document);
  document.addEventListener('touchend', function(){ sweep(document); }, {passive:true});
  var mo = new MutationObserver(function(records){
    for (var i = 0; i < records.length; i++){
      var nodes = records[i].addedNodes || [];
      for (var j = 0; j < nodes.length; j++){
        var n = nodes[j];
        if (!n || n.nodeType !== 1) continue;
        if (n.tagName === 'VIDEO') prep(n);
        sweep(n);
      }
    }
  });
  mo.observe(document.documentElement, {childList:true, subtree:true});
  setInterval(function(){ sweep(document); }, 1500);
})();
''');
  }

  void _injectCameraShim() {
    // Strips `capture` attributes and blocks getUserMedia so a site's
    // "camera" button falls back to file/photo selection instead of killing
    // the app with an iOS privacy exception.
    _wv.runJavaScript(r'''
(function(){
  if (window.__tfCamShim) return;
  window.__tfCamShim = true;
  function neuter(input){
    try {
      if (!input || input.tagName !== 'INPUT') return;
      if ((input.type || '').toLowerCase() !== 'file') return;
      if (input.hasAttribute('capture')) input.removeAttribute('capture');
      var accept = (input.getAttribute('accept') || '').toLowerCase();
      if (accept.indexOf('video') !== -1 || accept.indexOf('audio') !== -1){
        input.setAttribute('accept', 'image/*');
      }
    } catch (_){}
  }
  function sweep(root){
    try {
      var list = (root || document).querySelectorAll('input[type=file]');
      for (var i = 0; i < list.length; i++) neuter(list[i]);
    } catch (_){}
  }
  sweep(document);
  var mo = new MutationObserver(function(records){
    for (var i = 0; i < records.length; i++){
      var r = records[i];
      if (r.type === 'attributes') neuter(r.target);
      else if (r.addedNodes) {
        for (var j = 0; j < r.addedNodes.length; j++){
          var node = r.addedNodes[j];
          if (node && node.nodeType === 1){
            neuter(node);
            sweep(node);
          }
        }
      }
    }
  });
  mo.observe(document.documentElement, {
    childList: true, subtree: true,
    attributes: true, attributeFilter: ['capture','accept','type']
  });
  try {
    var blocked = function(){
      return Promise.reject(new DOMException('Not allowed', 'NotAllowedError'));
    };
    if (navigator.mediaDevices){
      navigator.mediaDevices.getUserMedia = blocked;
      navigator.mediaDevices.getDisplayMedia = blocked;
    } else {
      Object.defineProperty(navigator, 'mediaDevices', {
        configurable: true,
        value: { getUserMedia: blocked, getDisplayMedia: blocked }
      });
    }
    if (navigator.getUserMedia) navigator.getUserMedia = function(_, __, err){
      try { err && err(new Error('NotAllowedError')); } catch(_){}
    };
  } catch(_){}
})();
''');
  }

  void _injectSafeAreaPatch() {
    _wv.runJavaScript(r'''
(function(){
  if (window.__tfSafeShim) return;
  window.__tfSafeShim = true;
  var ID = '__tfSafeShim';
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
    + 'html,body,#root,#app,#__nuxt,#__layout,.gameview-mobile-header{'
    + 'padding-top:0!important;padding-left:0!important;padding-right:0!important;margin-top:0!important;'
    + '}';
  function paint(){
    var head = document.head || document.documentElement;
    if (!head) return;
    var meta = document.querySelector('meta[name="viewport"]');
    if (meta && !/viewport-fit\s*=\s*contain/i.test(meta.getAttribute('content') || '')){
      var c = (meta.getAttribute('content') || '').replace(/,?\s*viewport-fit\s*=\s*\w+/ig,'').trim();
      meta.setAttribute('content', c + (c ? ', ' : '') + 'viewport-fit=contain');
    }
    var s = document.getElementById(ID);
    if (!s){ s = document.createElement('style'); s.id = ID; head.appendChild(s); }
    if (s.textContent !== CSS) s.textContent = CSS;
    if (head.lastElementChild !== s) head.appendChild(s);
  }
  paint();
  ['pushState', 'replaceState'].forEach(function(name){
    var orig = history[name];
    history[name] = function(){
      var r = orig.apply(this, arguments);
      setTimeout(paint, 80); setTimeout(paint, 400);
      return r;
    };
  });
  window.addEventListener('popstate', function(){ setTimeout(paint, 80); });
  setInterval(paint, 2500);
})();
''');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connSub?.cancel();
    widget.pulse.onPushDestination = null;
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    _applyOrientations();
    super.dispose();
  }

  Future<bool> _onBack() async {
    if (_fullscreen != null) {
      _hideFullscreen?.call();
      return false;
    }
    try {
      if (await _wv.canGoBack()) {
        final current = await _wv.currentUrl();
        if (current != null &&
            _firstFinalUrl != null &&
            current == _firstFinalUrl) {
          return false;
        }
        await _wv.goBack();
      }
    } catch (err) {
      debugPrint('[TF.WV] back navigation failed: $err');
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _onBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        // OrientationBuilder forces a rebuild on every rotation so the
        // computed safe-area / chip bar are recalculated for the new
        // orientation instead of reusing the portrait values.
        body: OrientationBuilder(
          builder: (context, orientation) {
            final media = MediaQuery.of(context);
            // viewPadding (not viewInsets.bottom) keeps safe-area insets
            // stable even when the soft keyboard is open. WKWebView resizes
            // its content itself.
            final safe = media.viewPadding;
            final isLandscape = orientation == Orientation.landscape;
            // Reserve a small bar at the top for the floating back chip so it
            // never overlaps the web content. In landscape we make it a touch
            // shorter because vertical space is precious.
            final chipBar = isLandscape ? 36.0 : 42.0;
            final topPadding = safe.top + chipBar;
            return Stack(
              fit: StackFit.expand,
              children: [
                Padding(
                  padding: EdgeInsets.only(
                    top: topPadding,
                    bottom: safe.bottom,
                    left: safe.left,
                    right: safe.right,
                  ),
                  child: WebViewWidget(controller: _wv),
                ),
                if (_loading)
                  const ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                          strokeWidth: 3.0,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Color(0xFFFFC107),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_fullscreen != null) Positioned.fill(child: _fullscreen!),
                Positioned(
                  left: safe.left + (isLandscape ? 6 : 10),
                  top: safe.top + (isLandscape ? 2 : 4),
                  child: _BackChip(
                    compact: isLandscape,
                    onTap: _onBack,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _BackChip extends StatelessWidget {
  final Future<bool> Function() onTap;
  final bool compact;

  const _BackChip({required this.onTap, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final pad = compact ? 7.0 : 9.0;
    final iconSize = compact ? 18.0 : 22.0;
    return Material(
      color: Colors.black.withValues(alpha: 0.42),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => onTap(),
        child: Padding(
          padding: EdgeInsets.all(pad),
          child: Icon(
            Icons.arrow_back_ios_new_rounded,
            color: Colors.white,
            size: iconSize,
          ),
        ),
      ),
    );
  }
}
