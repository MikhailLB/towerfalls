# Gray Part — Architecture & Integration Guide

> **Audience:** human developers AND AI coding assistants tasked with
> integrating this module into another Flutter Android app. Read it once;
> every design decision below is load-bearing.

---

## 0. What this module IS

The **gray flow** is a Flutter Android boot pipeline that decides on every
launch whether to:

1. **Open a WebView** at a backend-supplied URL (the "gray" experience —
   typically a partner / affiliate landing page that the user reached via a
   paid install), or
2. **Hand control to the host app's own home screen** (the "white"
   experience — organic users, denied installs, or any case where the
   gateway has no destination for this device).

It does so by combining four moving parts:

| Part | Purpose | Key files |
|---|---|---|
| **AppsFlyer** attribution | Decides if the install is `Non-organic` and exposes the conversion payload (`af_status`, `campaign`, `media_source`, `adset`, …) | `services/install_signal_client.dart` |
| **Remote gateway** | POST'd with the conversion payload + device info; replies with `{ok: true, url: ...}` or `{ok: false}` | `services/remote_gate_client.dart` |
| **Firebase Cloud Messaging** + tray | Push opt-in, foreground rich notifications, cold-start URL routing | `services/pulse_dispatch.dart` |
| **WebView shell** | Hosts the gateway URL, handles full-screen video, file picker, push-driven navigation, offline detection | `screens/browser_shell.dart` |

The whole pipeline is encapsulated behind one facade: **`GrayBoot`**.

---

## 1. The 90-second integration

```dart
// pubspec.yaml — merge dependencies from this template's pubspec.

// android/app/src/main/AndroidManifest.xml — see §5.

// android/app/build.gradle.kts — see §5.

// lib/main.dart in your HOST app:
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'gray/gray_boot.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  final gray = await GrayBoot.prepare();

  runApp(MaterialApp(
    title: 'My App',
    home: gray.buildHome(
      fallbackHomeBuilder: (_) => const MyExistingHomeScreen(),
    ),
  ));
}
```

That's it. With no keys provisioned, `GrayBoot` short-circuits to your home
screen. Once you fill in the AppsFlyer + gateway keys (§3) the gray flow
starts deciding routes per launch.

---

## 2. Folder map

```
lib/
├── gray/
│   ├── gray_boot.dart                ← facade: GrayBoot.prepare() / buildHome()
│   ├── config/
│   │   ├── runtime_brand.dart        ← AppsFlyer key, Firebase project, bundle id, ATT cooldown
│   │   ├── gateway_endpoints.dart    ← gateway URL, GCD host, fake UA versions
│   │   └── gray_assets.dart          ← OPTIONAL asset overrides for the branded screens
│   ├── models/
│   │   ├── launch_route.dart         ← LaunchRoute { web, arcade, pristine }
│   │   └── gate_response.dart        ← decoded gateway response (granted / destination / TTL)
│   ├── screens/
│   │   ├── entry_gate.dart           ← orchestrator — runs the boot pipeline
│   │   ├── default_splash.dart       ← built-in Material splash (host can replace)
│   │   ├── notify_offer_screen.dart  ← branded "Allow notifications?" prompt
│   │   ├── browser_shell.dart        ← WebView shell, JS injection, push routing
│   │   └── network_pause_screen.dart ← offline state with retry
│   ├── services/
│   │   ├── runtime_cache.dart        ← SharedPreferences + FlutterSecureStorage
│   │   ├── network_radar.dart        ← connectivity probe with real DNS lookup
│   │   ├── secure_http.dart          ← http.BaseClient that injects a believable mobile UA
│   │   ├── install_signal_client.dart ← AppsFlyer wrapper + payload composer
│   │   ├── remote_gate_client.dart   ← POST to RuntimeBrand.configUrl, parse reply
│   │   └── pulse_dispatch.dart       ← FCM + flutter_local_notifications wrapper
│   └── utils/
│       └── byte_unmask.dart          ← XOR de-obfuscation for compile-time secrets
├── main.dart                         ← reference entry point (replace in host app)

android/
├── app/
│   ├── build.gradle.kts              ← signing config, conditional google-services apply
│   ├── google-services.json          ← REQUIRED for FCM (do not commit; gitignored)
│   ├── src/main/
│   │   ├── AndroidManifest.xml       ← permissions, FCM meta, network policy, adjustPan
│   │   ├── kotlin/.../MainActivity.kt
│   │   └── res/
│   │       ├── drawable/ic_pulse_notification.xml  ← white-mono FCM tray icon
│   │       └── xml/
│   │           ├── gray_network_policy.xml   ← allow cleartext, system CAs only
│   │           └── gray_data_extraction.xml  ← opt out of Google Backup
│   └── key.properties                ← signing secrets (gitignored)

tool/
└── encode_keys.dart                  ← run with `dart run tool/encode_keys.dart`
                                        to generate obfuscated byte arrays
```

---

## 3. Configuration — what you MUST set

All secrets are stored as **obfuscated byte arrays** so they don't appear as
readable strings in the compiled APK. Use the helper to encode:

```bash
# Edit `tool/encode_keys.dart`, fill in the `secrets` map, then:
dart run tool/encode_keys.dart
```

Paste the printed byte arrays into the matching constants:

### `lib/gray/config/runtime_brand.dart`

| Constant | What | Source |
|---|---|---|
| `_installKeyAndroid` | AppsFlyer dev key for Android | AppsFlyer dashboard → App settings |
| `_installKeyIos` | AppsFlyer dev key for iOS (template branch is Android-only, leave empty) | same |
| `_firebaseProjectAndroid` | Numeric Firebase project number | Firebase console → Project settings |
| `_firebaseProjectIos` | Same for iOS | same |
| `packageName` | `com.your.app` (must match `applicationId` in build.gradle) | — |
| `displayTitle` | Plain string used in any user-facing copy the gray flow renders | — |
| `iosAppId` | App Store numeric ID — only relevant if you later add iOS | App Store Connect |

### `lib/gray/config/gateway_endpoints.dart`

| Constant | What | Source |
|---|---|---|
| `_gateUrlMask` | `https://your.api/gate` — endpoint that accepts the install payload | brand backend |
| `_gcdHostMask` | AppsFlyer GCD (Get Conversion Data) endpoint — used as a fallback when the SDK callback is missed for an Organic install | AppsFlyer dashboard |
| `brandPrivacyUrl` | Your Privacy Policy URL (link is exposed via `RuntimeBrand.privacyUrl`) | brand site |
| `brandSupportUrl` | Your Support URL | brand site |

When **all** install keys AND the gateway URL are empty, `RuntimeBrand.gateEnabled` returns `false`
and `GrayBoot.buildHome()` mounts the host's `fallbackHomeBuilder` directly — no AppsFlyer init,
no Firebase init runs unless your host app calls them itself.

### `android/app/google-services.json`

Required for FCM. Download from Firebase console → Project → Add Android app
→ matching `applicationId`. **Do not commit it** — `.gitignore` already
excludes it. The Gradle plugin only applies the `com.google.gms.google-services`
plugin when this file is present, so the build stays green without it.

### `android/key.properties`

Required for release builds. Format:

```
storePassword=...
keyPassword=...
keyAlias=upload
storeFile=/abs/path/to/upload-keystore.jks
```

Gitignored. The `build.gradle.kts` checks `keystorePropertiesFile.exists()`
before wiring the release signing config — without it, release builds fall
back to the debug keystore so the build still succeeds for local testing.

---

## 4. Optional branding — `GrayAssets`

The four user-facing screens (`DefaultGraySplash`, `NotifyOfferScreen`,
`NetworkPauseScreen`, plus the WebView host) ship without any bundled
artwork. To brand them, drop assets into `pubspec.yaml` AND configure
`GrayAssets` BEFORE `runApp`:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  GrayAssets.configure(
    notifyOfferVideoPortrait:  'assets/gray/notify/9x16.mp4',
    notifyOfferVideoLandscape: 'assets/gray/notify/16x9.mp4',
    notifyOfferBackground:     'assets/gray/notify/bg.webp',
    networkPauseBackgroundPortrait:  'assets/gray/offline/9x16.webp',
    networkPauseBackgroundLandscape: 'assets/gray/offline/16x9.webp',
    networkPauseRetryButton:         'assets/gray/offline/retry_btn.webp',
  );
  final gray = await GrayBoot.prepare();
  ...
}
```

Any field left null falls back to a Material/gradient default. The splash
itself does not have an asset slot — to replace it entirely, pass a
`splashBuilder` to `gray.buildHome(...)`. See
[`screens/default_splash.dart`](lib/gray/screens/default_splash.dart) for the
contract the splash widget MUST honour (route resolution + content-ready +
keep-as-underlay).

---

## 5. Android native plumbing

### `AndroidManifest.xml` — required entries

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<!-- POST_NOTIFICATIONS is the Android 13+ runtime permission — requested
     from Dart via pulse.askConsent(). Without it, no banners are shown. -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>

<application
    android:label="..."
    android:networkSecurityConfig="@xml/gray_network_policy"
    android:dataExtractionRules="@xml/gray_data_extraction"
    android:allowBackup="false"
    android:fullBackupContent="false"
    tools:replace="android:allowBackup,android:fullBackupContent,android:dataExtractionRules">

  <activity
      android:name=".MainActivity"
      android:exported="true"
      android:launchMode="singleTop"
      android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
      android:hardwareAccelerated="true"
      android:windowSoftInputMode="adjustPan">
    <!-- ↑ adjustPan, NOT adjustResize.
         WebView (PlatformView) re-layouts on every window resize, which
         causes a visible "jitter" while the soft keyboard animates in.
         adjustPan slides the entire window up instead — no relayout,
         no jitter. JS code in browser_shell.dart still scrolls the
         focused input into view via window.visualViewport. -->
    ...
  </activity>

  <!-- FCM defaults. The icon resource and channel id MUST match the
       values pulse_dispatch.dart uses. -->
  <meta-data
      android:name="com.google.firebase.messaging.default_notification_icon"
      android:resource="@drawable/ic_pulse_notification" />
  <meta-data
      android:name="com.google.firebase.messaging.default_notification_channel_id"
      android:value="gray_pulse_channel" />
</application>

<queries>
  <!-- Required so url_launcher can resolve external schemes from
       BrowserShell._launchExternal(...) on Android 11+. -->
  <intent>
    <action android:name="android.intent.action.VIEW"/>
    <data android:scheme="https"/>
  </intent>
  <intent>
    <action android:name="android.intent.action.VIEW"/>
    <data android:scheme="http"/>
  </intent>
  <intent>
    <action android:name="android.intent.action.VIEW"/>
    <data android:scheme="tel"/>
  </intent>
  <intent>
    <action android:name="android.intent.action.VIEW"/>
    <data android:scheme="mailto"/>
  </intent>
</queries>
```

### `xml/gray_network_policy.xml`

```xml
<network-security-config>
  <base-config cleartextTrafficPermitted="true">
    <trust-anchors>
      <certificates src="system" />
      <!-- DO NOT add <certificates src="user" />.
           Trusting user-installed CAs enables locally-installed MITM
           certificates and is a Play Review red flag. The reason cleartext
           HTTP is permitted is to follow redirect chains (some partner
           hops are plain http:// before landing on the final https://). -->
    </trust-anchors>
  </base-config>
</network-security-config>
```

### `xml/gray_data_extraction.xml`

Opts out of Google Backup / device transfer for the gray cache so a
restored device does not bring a stale `LaunchRoute.web` into a fresh
install.

### `build.gradle.kts` — required bits

```kotlin
plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// Conditional plugin apply — the build stays green without google-services.json.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

android {
    namespace = "com.your.app"          // ← MUST match RuntimeBrand.packageName
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true  // required by flutter_local_notifications
    }

    defaultConfig {
        applicationId = "com.your.app"
        minSdk = 26                     // FCM + adaptive notification icon
        targetSdk = 35
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
```

### Settings root `android/settings.gradle.kts`

The Google Services plugin must be declared at the root:

```kotlin
plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
    id("com.google.gms.google-services") version "4.4.2" apply false
}
```

---

## 6. Boot pipeline — step by step

```
                            GrayBoot.prepare()
                                   │
                                   ▼
                ┌──────────────────────────────────────┐
                │ Firebase.initializeApp + AppCheck    │
                │ secureHttp.warmup (compose mobile UA)│
                │ RuntimeCache.bootstrap (SharedPrefs) │
                │ instantiate radar / install / gate / │
                │             pulse                    │
                └──────────────────┬───────────────────┘
                                   │
                                   ▼
                       gray.buildHome(fallbackHomeBuilder)
                                   │
                ┌──────────────────┴───────────────────┐
                │ RuntimeBrand.gateEnabled?            │
                └─────┬────────────────────────┬───────┘
                  yes │                        │ no
                      ▼                        ▼
                EntryGate              fallbackHomeBuilder
                      │
                      ▼
       ┌──────────────────────────┐
       │ pulse.bootstrap()        │   (FCM + tray + cold-start init msg)
       └──────────┬───────────────┘
                  ▼
       cache.readRoute()
            │
            ├── LaunchRoute.web     ──► _runReturningWebFlow()
            ├── LaunchRoute.arcade  ──► fallbackHomeBuilder
            └── LaunchRoute.pristine──► _runFirstLaunchFlow()
                                          │
                                          ▼
                  install.warmup() + AppsFlyer init
                  await conversion (≤ 25 s) + deep-link (≤ 5 s)
                                          │
                                          ▼
                  install.composePayload(locale, push_token)
                                          │
                                          ▼
                  gate.dispatch(payload)         (HTTP POST, 18s timeout)
                                          │
                  granted=true & destination ?
                      │                │
                  yes │                │ no
                      ▼                ▼
                  writeRoute=web    writeRoute=arcade
                  _webBuilder(url)  fallbackHomeBuilder
                       │
                       ▼
              needsPushPrompt && canAsk ?
                      │
                  yes │
                      ▼
                NotifyOfferScreen ── Accept ──► askConsent (system prompt)
                          │                                │
                          │                                ▼
                          └─── Skip ──────────► BrowserShell(destination)
```

The `LaunchRoute` is persisted in SharedPreferences, so on subsequent
launches the pipeline knows whether to go through the heavy AppsFlyer +
gateway round-trip (`pristine`) or the lighter "returning user" path
(`web` — only re-validates with the gateway if a cached destination is
absent or expired).

---

## 7. Push notifications — full lifecycle

### Foreground

`FirebaseMessaging.onMessage` fires → `pulse_dispatch._onForeground` →
local `flutter_local_notifications` shows a banner with the rich image
attached. Tap routes through `onPushDestination` callback (set by
`BrowserShell.initState`) → live WebView reloads with the URL.

### Background (app suspended, not killed)

System tray shows the notification with the image directly from FCM
payload. Tap → `FirebaseMessaging.onMessageOpenedApp` → same
`onPushDestination` callback → live WebView reloads.

### Cold start (process killed)

This is the load-bearing edge case. Sequence:

1. User taps notification → Android launches the process.
2. `FirebaseMessaging.getInitialMessage()` returns the `RemoteMessage`
   carried by the launch intent. **On Android this is reliable**, unlike
   iOS scene-based apps where a native `SceneDelegate` interception is
   required.
3. `pulse_dispatch._onColdStart()` extracts `data.url` and stashes it via
   `cache.stashOneShotPush(url)` (writes to FlutterSecureStorage).
4. `EntryGate._kickoff()` finishes `pulse.bootstrap()`, reads the cached
   route, and on the `returning-web` path calls
   `cache.consumeOneShotPush()` BEFORE re-validating with the gateway —
   so the user lands on the push URL even if the gateway is slow.

### Push payload contract

The backend MUST send pushes with:

```json
{
  "notification": { "title": "...", "body": "...", "image": "https://..." },
  "data":         { "url": "https://destination/page", ... },
  "android":      { "priority": "high" }
}
```

The URL key is read from `data.url`. `data.{link,target,deeplink,deep_link}`
are also accepted as aliases via the same `_extractUrl` helper.

---

## 8. WebView — what BrowserShell does

`browser_shell.dart` is intentionally thick. It owns:

- **JavaScript injection on every `onPageFinished`** —
  - `_injectKeyboardScroll`: monkey-patches `focusin` + `visualViewport.resize`
    so focused inputs are scrolled into view when the soft keyboard pops up.
    Works in tandem with `adjustPan` in the manifest.
  - `_injectSafeAreaPatch`: forces every `safe-area-inset-*` CSS var to 0px
    so partner sites with `padding: env(safe-area-inset-top)` don't double-
    pad on top of the immersive-mode status bar.
- **Redirect-chain debounce** for `onFirstPaint`: a single `onPageFinished`
  is unreliable because gateways often redirect through 3-5 blank pages.
  We wait for `_firstPaintQuietPeriod` (700ms) of "no new navigation" before
  considering the page actually painted. This is what keeps the loading
  splash visible until the real page is on screen.
- **Loop-redirect break-out**: if `onWebResourceError` reports
  `too_many_redirects` / WKErrorCode -1007 / -9, we retry the last main
  frame up to 3 times before giving up to `NetworkPauseScreen`.
- **File picker / camera**: WebView `<input type="file">` and similar
  fall through to `file_picker` / `image_picker` via the
  `AndroidWebViewController.setOnShowFileSelector` hook.
- **Push-driven reload**: `widget.pulse.onPushDestination = (url) => _wv.loadRequest(...)`.
- **Offline detection**: `connectivity_plus` stream → if all interfaces
  drop, route to `NetworkPauseScreen` and replace the WebView with the
  retry UI.
- **Back navigation**: `PopScope(canPop: false)` + custom back handler so
  the device back button never accidentally closes the activity while the
  user is mid-page.

The WebView is **the** stateful widget that must survive the splash → ready
handover. That's why `EntryGate._kickoff()` sets `_keepUnderlay = true` for
web routes — the splash is rendered above the BrowserShell, fades out, and
disposes itself without ever rebuilding the WebView's element subtree.

---

## 9. Gotchas / known-failure modes

| Symptom | Root cause | Fix |
|---|---|---|
| WebView "jitters" while soft keyboard animates in | `android:windowSoftInputMode="adjustResize"` triggers full PlatformView relayout | Use `adjustPan` (already set in template). |
| `[core/duplicate-app]` exception on second `Firebase.initializeApp()` | Host app also calls `Firebase.initializeApp()` | `GrayBoot` handles it via try/catch; if you have your own call, leave only one — they're not additive. |
| Tray notification never appears on Android 13+ | App didn't request `POST_NOTIFICATIONS` runtime permission | Make sure `pulse.askConsent()` is called (the `NotifyOfferScreen` does this on "Accept"); or trigger it from your own UI. |
| Cold-start push opens app to wrong page | Backend sent the URL under a non-standard key | The gray flow scans `data.{url,link,target,deeplink,deep_link}` — but only those. Either align the backend, or extend `_extractUrl` in `pulse_dispatch.dart`. |
| Build error "Manifest merger failed: data extraction rules" | Host app has its own `dataExtractionRules` | Either delete the host's rule (and let `gray_data_extraction.xml` win) or merge them — but keep the gray exclusions, otherwise SharedPreferences survives device restore and a fresh install inherits a stale `LaunchRoute.web`. |
| `Adb install` succeeds but app crashes immediately on launcher tap | `applicationId` in `build.gradle.kts` does not match `MainActivity` package | Both must agree with `namespace`. If you rename the Kotlin package, also rename `applicationId` AND the folder under `kotlin/`. |
| App passes Play Pre-Launch report but rejects at policy review | `user` CA trust anchor + `cleartextTrafficPermitted` is a flag combination | The template keeps only `system` CAs while still permitting cleartext. Do not add `user` CAs unless you absolutely have to. |
| Notification image missing on Android | Backend forgot `notification.image` field OR the image URL is HTTP-only | The gray flow downloads it via `secureHttp` and renders it as a `BigPictureStyleInformation` locally. If the URL is HTTP, it works only because of `cleartextTrafficPermitted="true"`. |
| `installDevKey` empty in production build | Compile-time obfuscation byte array left as `<>` after a forgotten `dart run tool/encode_keys.dart` | Run the tool, paste the output back, rebuild. `gateEnabled` will return `false` until both `configUrl` and `installDevKey` resolve to non-empty strings. |

---

## 10. Privacy / store-policy notes

The gray flow is an **attribution-aware deep-link router** — it collects
device identifiers (AppsFlyer ID, IDFA on iOS only, push token) and posts
them to the brand backend for routing. To stay on the right side of Play
Policy:

- Treat the entire flow as **personalised advertising / tracking** for the
  purposes of the Play Console Data Safety form.
- Mention AppsFlyer + Firebase Cloud Messaging as data-sharing partners.
- The bundled Privacy URL (`brandPrivacyUrl`) MUST be reachable AND
  describe what you collect (AppsFlyer ID, device model, push token,
  approximate locale).
- Cleartext HTTP is permitted globally (for redirect chains). User CAs
  are explicitly NOT trusted. Both are deliberate — see comments in
  `gray_network_policy.xml`.
- Notification consent is requested via the standard system prompt
  (`POST_NOTIFICATIONS` on Android 13+); the in-app `NotifyOfferScreen`
  is a pre-warning, not the actual permission grant.

---

## 11. Updating the obfuscated salt

`utils/byte_unmask.dart` and `tool/encode_keys.dart` MUST keep the same
`_saltBytes` constant. If you ever change it, every byte array in
`runtime_brand.dart` and `gateway_endpoints.dart` becomes garbage and
the gray flow short-circuits to the host home (silent failure — search
the debug log for `gateEnabled=false` in `_doBootstrap`).

---

## 12. Hand-over checklist for new integrations

- [ ] `applicationId` in `build.gradle.kts` matches `RuntimeBrand.packageName`
- [ ] `MainActivity.kt` package matches `applicationId`
- [ ] `google-services.json` placed under `android/app/`
- [ ] AppsFlyer dev key encoded into `_installKeyAndroid`
- [ ] Firebase project number encoded into `_firebaseProjectAndroid`
- [ ] Gateway URL encoded into `_gateUrlMask`
- [ ] `brandPrivacyUrl` + `brandSupportUrl` updated (must be reachable)
- [ ] `android:label` in `AndroidManifest.xml` set to your app name
- [ ] App icon (`@mipmap/ic_launcher`) and notification icon
      (`@drawable/ic_pulse_notification`, white-mono vector) shipped
- [ ] Adaptive icon background colour matched to your brand
- [ ] `assets/gray/...` populated AND `GrayAssets.configure(...)` called
      (optional — defaults are functional)
- [ ] `android/key.properties` + keystore generated; release build signs OK
- [ ] Verified `gray.buildHome(fallbackHomeBuilder:)` falls through to the
      host home when the device is offline AND the cache is empty
- [ ] Verified push notification with `data.url` lands the user on that
      URL from a cold start
- [ ] Verified the `NotifyOfferScreen` Accept → system prompt → granted
      path on a fresh install
- [ ] Verified Play Console Data Safety form mentions AppsFlyer + FCM

When every box is ticked the integration is ready for an internal QA pass.
