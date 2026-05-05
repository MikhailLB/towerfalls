import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../services/network_radar.dart';
import '../services/pulse_dispatch.dart';
import '../services/runtime_cache.dart';
import '../services/secure_http.dart';
import 'network_pause_screen.dart';

enum _MediaSource { gallery, camera }

/// In-app browser used when the gateway returns a destination URL. Keeps the
/// session sticky to the first landed page and routes external schemes via
/// the OS so the experience matches a real mobile browser.
class BrowserShell extends StatefulWidget {
  final String destination;
  final RuntimeCache cache;
  final PulseDispatch pulse;
  final NetworkRadar radar;
  // Fires once on the first successful onPageFinished. EntryGate uses this
  // to keep the loading splash visible until the WebView has actually
  // painted its first page, so the progress bar never reaches 100% before
  // the web content is on screen.
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
  final ImagePicker _mediaPicker = ImagePicker();
  bool _loading = true;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  bool _routedOffline = false;
  String? _lastMainFrame;
  int _redirectRetries = 0;
  String? _firstFinalUrl;
  bool _firstPaintFired = false;
  // Debounces the "page is actually visible" signal across redirect chains.
  // onPageFinished fires for EVERY page in the chain (incl. the intermediate
  // 30x landing pages that are usually blank), so naively firing onFirstPaint
  // on the very first onPageFinished would hide the splash before the real
  // landing page is on screen — which is exactly what the user reported as
  // "loading bar at 100% then web shows up a couple of seconds later".
  Timer? _firstPaintDebouncer;
  static const Duration _firstPaintQuietPeriod = Duration(milliseconds: 700);

  Widget? _fullscreen;
  void Function()? _hideFullscreen;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applyOrientations();
    _applyFullscreen();

    _wv = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(secureHttp.userAgent)
      ..setBackgroundColor(Colors.black)
      ..enableZoom(false)
      ..setNavigationDelegate(_buildDelegate());

    _attachPlatform();
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

  void _applyFullscreen() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _applyFullscreen();
  }

  NavigationDelegate _buildDelegate() {
    return NavigationDelegate(
      onPageStarted: (_) {
        if (mounted) setState(() => _loading = true);
        // A new page started loading → the previous onPageFinished was
        // probably a redirect, so cancel any pending first-paint signal and
        // wait for the next "settled" page.
        _firstPaintDebouncer?.cancel();
      },
      onPageFinished: (url) {
        if (mounted) setState(() => _loading = false);
        _redirectRetries = 0;
        _firstFinalUrl ??= url;
        _injectKeyboardScroll();
        _injectSafeAreaPatch();
        _scheduleFirstPaint();
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
          if (req.isMainFrame) {
            _lastMainFrame = req.url;
            // Main-frame navigation in flight → another redirect is likely
            // coming. Cancel any pending first-paint we had scheduled.
            _firstPaintDebouncer?.cancel();
          }
          return NavigationDecision.navigate;
        }
        _launchExternal(uri);
        return NavigationDecision.prevent;
      },
    );
  }

  // Schedules a first-paint notification that fires only after the WebView
  // has been quiet (no further onPageStarted / main-frame navigation) for
  // [_firstPaintQuietPeriod]. This collapses redirect chains down to a
  // single signal — the splash hand-off then matches the moment the actual
  // landing page is on screen instead of an intermediate blank redirect.
  void _scheduleFirstPaint() {
    if (_firstPaintFired) return;
    _firstPaintDebouncer?.cancel();
    _firstPaintDebouncer = Timer(_firstPaintQuietPeriod, () {
      if (!mounted || _firstPaintFired) return;
      _firstPaintFired = true;
      try {
        widget.onFirstPaint?.call();
      } catch (_) {}
    });
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
      final accepts = _normalizedAcceptTypes(params.acceptTypes);
      final wantsVideo = _acceptsVideo(accepts);
      final wantsImage = _acceptsImage(accepts);

      // Most mobile upload fields are photo/video inputs. Prefer Android's
      // system photo picker and camera intents via image_picker: no storage
      // permissions are added to AndroidManifest, and the app avoids exposing
      // a broad document manager unless the site explicitly requests files.
      if (wantsImage || wantsVideo) {
        final files = await _pickMediaForWebInput(
          allowMultiple: params.mode == FileSelectorMode.openMultiple,
          wantsImage: wantsImage,
          wantsVideo: wantsVideo,
          captureOnly: params.isCaptureEnabled,
        );
        return _toFileUris(files);
      }

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: params.mode == FileSelectorMode.openMultiple,
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'txt', 'doc', 'docx'],
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

  List<String> _normalizedAcceptTypes(List<String> raw) {
    return raw
        .map((v) => v.trim().toLowerCase())
        .where((v) => v.isNotEmpty)
        .toList(growable: false);
  }

  bool _acceptsImage(List<String> accepts) {
    if (accepts.isEmpty) return true;
    return accepts.any((v) =>
        v == '*/*' ||
        v == 'image/*' ||
        v.startsWith('image/') ||
        const {'.jpg', '.jpeg', '.png', '.webp', '.gif'}.contains(v));
  }

  bool _acceptsVideo(List<String> accepts) {
    if (accepts.isEmpty) return true;
    return accepts.any((v) =>
        v == '*/*' ||
        v == 'video/*' ||
        v.startsWith('video/') ||
        const {'.mp4', '.mov', '.webm', '.m4v'}.contains(v));
  }

  Future<List<XFile>> _pickMediaForWebInput({
    required bool allowMultiple,
    required bool wantsImage,
    required bool wantsVideo,
    required bool captureOnly,
  }) async {
    if (captureOnly) {
      final captured = wantsVideo && !wantsImage
          ? await _mediaPicker.pickVideo(source: ImageSource.camera)
          : await _mediaPicker.pickImage(source: ImageSource.camera);
      return captured == null ? const [] : [captured];
    }

    final source = await _showMediaSourceSheet(
      allowCamera: !allowMultiple,
      wantsImage: wantsImage,
      wantsVideo: wantsVideo,
    );
    if (source == null) return const [];

    switch (source) {
      case _MediaSource.gallery:
        if (allowMultiple) {
          if (wantsImage && wantsVideo) return _mediaPicker.pickMultipleMedia();
          if (wantsImage) return _mediaPicker.pickMultiImage();
        }
        final picked = wantsImage && wantsVideo
            ? await _mediaPicker.pickMedia()
            : wantsVideo
                ? await _mediaPicker.pickVideo(source: ImageSource.gallery)
                : await _mediaPicker.pickImage(source: ImageSource.gallery);
        return picked == null ? const [] : [picked];
      case _MediaSource.camera:
        final captured = wantsVideo && !wantsImage
            ? await _mediaPicker.pickVideo(source: ImageSource.camera)
            : await _mediaPicker.pickImage(source: ImageSource.camera);
        return captured == null ? const [] : [captured];
    }
  }

  Future<_MediaSource?> _showMediaSourceSheet({
    required bool allowCamera,
    required bool wantsImage,
    required bool wantsVideo,
  }) {
    if (!mounted) return Future.value(null);
    final captureLabel = wantsVideo && !wantsImage ? 'Record video' : 'Take photo';
    return showModalBottomSheet<_MediaSource>(
      context: context,
      backgroundColor: const Color(0xFF101521),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (allowCamera)
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined,
                    color: Colors.white),
                title: Text(
                  captureLabel,
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () => Navigator.of(ctx).pop(_MediaSource.camera),
              ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined,
                  color: Colors.white),
              title: const Text(
                'Choose from gallery',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.of(ctx).pop(_MediaSource.gallery),
            ),
          ],
        ),
      ),
    );
  }

  List<String> _toFileUris(List<XFile> files) {
    return files
        .where((f) => f.path.isNotEmpty)
        .map((f) => Uri.file(f.path).toString())
        .toList(growable: false);
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
  function isInput(n){
    return n && (n.tagName === 'INPUT' || n.tagName === 'TEXTAREA' || n.isContentEditable);
  }
  function pull(){
    var el = document.activeElement;
    if (!isInput(el)) return;
    var vp = window.visualViewport;
    if (vp){
      var rect = el.getBoundingClientRect();
      if (rect.bottom > vp.offsetTop + vp.height - 24 || rect.top < vp.offsetTop){
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
      if (h < prev){ setTimeout(pull, 80); setTimeout(pull, 320); }
      prev = h;
    });
  }
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
    _firstPaintDebouncer?.cancel();
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
    if (await _wv.canGoBack()) {
      final current = await _wv.currentUrl();
      if (current != null &&
          _firstFinalUrl != null &&
          current == _firstFinalUrl) {
        return false;
      }
      await _wv.goBack();
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
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Respect display cutout (camera notch) in both orientations
            // without adding status-bar/nav-bar padding. In immersiveSticky
            // mode MediaQuery.padding reflects only the cutout insets (the
            // hidden status bar is no longer counted), so this keeps the
            // WebView content clear of the physical notch on all devices.
            Padding(
              padding: MediaQuery.of(context).padding,
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
          ],
        ),
      ),
    );
  }
}
