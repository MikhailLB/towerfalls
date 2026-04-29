# Tower Falls — iOS release guide

Бранч: `white-ios-deploy` (white) / `gray-part-ios` (gray).

Все шаги выполняются **только на macOS** (нужен Xcode 16 или новее и установленный CocoaPods).

## Идентификаторы приложения

| Что | Значение |
| --- | --- |
| Bundle ID | `com.tstudiomgames.towerfalls` |
| App Store Connect **Apple ID (App ID)** | `6763527518` |
| App Store Connect record | https://appstoreconnect.apple.com/apps/6763527518 |

Bundle ID используется Xcode при подписи и сборке, а числовой Apple ID
(`6763527518`) нужен для `ExportOptions.plist`, `fastlane`, deep links и
любых автоматизированных выгрузок через `xcodebuild -exportArchive` /
Transporter CLI (`iTMSTransporter`).

## 1. Конфигурация, которая уже в репозитории

- `ios/Podfile` — `platform :ios, '13.0'`, `post_install` форсит
  `IPHONEOS_DEPLOYMENT_TARGET = 13.0` для всех подов и выключает bitcode.
- `ios/Runner.xcodeproj/project.pbxproj`:
  - `PRODUCT_BUNDLE_IDENTIFIER = com.tstudiomgames.towerfalls` (Debug / Release / Profile)
  - `IPHONEOS_DEPLOYMENT_TARGET = 13.0`
  - `TARGETED_DEVICE_FAMILY = "1,2"` (iPhone + iPad)
- `ios/Flutter/AppFrameworkInfo.plist` — `MinimumOSVersion = 13.0`.
- `ios/Runner/Info.plist`:
  - `CFBundleDisplayName = Tower Falls`
  - iPhone orientations: Portrait, PortraitUpsideDown, LandscapeLeft, LandscapeRight
  - iPad orientations: Portrait, PortraitUpsideDown, LandscapeLeft, LandscapeRight
  - `UIRequiresFullScreen = true` (отключает split view на iPad,
    фиксирует наш лок по ориентации)
  - `UIStatusBarHidden = true`, `UIViewControllerBasedStatusBarAppearance = false`
  - `ITSAppUsesNonExemptEncryption = false` (не используем шифрование за рамками
    стандартного HTTPS, сразу проходит экспортный контроль в App Store Connect)

Ориентации в самом приложении по-прежнему ограничены `SystemChrome`
(главное меню / игра — только вертикальные `portraitUp/portraitDown`,
loading screen — вертикальные + `landscapeLeft/Right`).

## 2. Зависимости и совместимость с iOS

Используем только свежие стабильные пакеты, у всех iOS-минимум ≤ 13.0:

| Пакет | Версия | iOS min |
| --- | --- | --- |
| `video_player` | `^2.9.2` | iOS 12+ |
| `shared_preferences` | `^2.3.3` | iOS 12+ |
| `url_launcher` | `^6.3.1` | iOS 12+ |
| `cupertino_icons` | `^1.0.8` | iOS 9+ |
| `flutter_launcher_icons` | `^0.14.1` (dev) | — |

Выставленный в проекте deployment target `iOS 13.0` с запасом покрывает
все пакеты и гарантированно проходит App Store review.

## 3. Первый запуск на Mac

```bash
# В корне репозитория
flutter pub get

cd ios
pod repo update            # обновить CocoaPods spec repo (разово)
pod install                # создаст Pods/ и Podfile.lock
cd ..

# Пересоздать иконки для iOS (logo.png лежит в assets/logo/)
dart run flutter_launcher_icons
```

## 4. Подпись в Xcode

1. Откройте `ios/Runner.xcworkspace` (именно workspace, не `.xcodeproj`).
2. В Xcode: target **Runner** → вкладка **Signing & Capabilities**.
3. Поставьте галочку **Automatically manage signing**.
4. В поле **Team** выберите ваш Apple Developer Team.
5. Bundle Identifier должен быть `com.tstudiomgames.towerfalls`
   (уже прописан в pbxproj). При необходимости создайте App ID
   в [Apple Developer → Identifiers](https://developer.apple.com/account/resources/identifiers/list).

## 5. Сборка релиза

```bash
# Чистый билд перед релизом — рекомендуется
flutter clean
flutter pub get
cd ios && pod install && cd ..

# IPA для App Store Connect
flutter build ipa --release --export-options-plist=ios/ExportOptions.plist
```

`ios/ExportOptions.plist` в репозитории заранее настроен на наш App Store
Connect App ID `6763527518` и bundle `com.tstudiomgames.towerfalls`. Если
будете собирать из CI — в нём же можно переключить `signingStyle` на
`manual` и раскомментировать `teamID`.

Готовый артефакт:

- `build/ios/ipa/tower_falls.ipa`
- Xcode archive: `build/ios/archive/Runner.xcarchive`

## 6. Загрузка в App Store Connect

Вариант 1 — через **Transporter** (проще всего):

1. Скачайте Transporter из Mac App Store.
2. Перетащите `build/ios/ipa/tower_falls.ipa`.
3. Нажмите **Deliver**.

Вариант 2 — из **Xcode**:

1. Откройте `ios/Runner.xcworkspace`.
2. Выберите схему **Runner** и target-device **Any iOS Device (arm64)**.
3. **Product → Archive**.
4. В Organizer: **Distribute App → App Store Connect → Upload**.

Вариант 3 — полностью автоматом (CI / скриптом):

```bash
# Нужен App Store Connect API key: ASC_KEY_ID, ASC_ISSUER_ID, AuthKey_*.p8
xcrun altool --upload-app \
  --type ios \
  --file build/ios/ipa/tower_falls.ipa \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"
```

App Store Connect сам привяжет билд к записи с Apple ID `6763527518`
по bundle id `com.tstudiomgames.towerfalls`.

## 7. Чек-лист перед релизом

- [ ] Версия в `pubspec.yaml` увеличена (`version: 1.0.0+1` → новая).
- [ ] Иконки сгенерированы (`dart run flutter_launcher_icons`).
- [ ] `flutter analyze` — без ошибок.
- [ ] Тестовый запуск на реальном iPhone и iPad (или симуляторах).
- [ ] В App Store Connect создана запись приложения с Bundle ID
      `com.tstudiomgames.towerfalls`.
- [ ] Заполнены Privacy Policy URL (`https://towerrfalls.com/privacy-policy.html`)
      и Support URL (`https://towerrfalls.com/support.html`).

## 8. Gray-flow на iOS (`gray-part-ios`)

Серая ветка добавляет Firebase + AppsFlyer + WebView боковой контур поверх
основного игрового UI. Все секреты обфусцированы внутри
`lib/gray/config/runtime_brand.dart` через `tool/encode_keys.dart`.

### 8.1. Файлы, которые НЕ коммитим

| Файл | Где лежит локально / в CI |
| --- | --- |
| `ios/Runner/GoogleService-Info.plist` | gitignored. На Codemagic заливается как **Environment file** (Files → Decrypt path: `ios/Runner/GoogleService-Info.plist`). |
| `tool/encode_keys.dart` с заполненными `secrets` | в `main()` плейн-значения подставляются временно, после генерации байтов значения возвращаются обратно к пустым строкам. |

### 8.2. Что появилось в `Info.plist`

| Ключ | Значение | Зачем |
| --- | --- | --- |
| `NSUserTrackingUsageDescription` | игровая формулировка про персонализацию | требуется для ATT-prompt перед `AppsflyerSdk.initSdk` |
| `UIBackgroundModes` → `remote-notification` | — | пробуждение по silent / data push |
| `FirebaseAppDelegateProxyEnabled` | `true` | стандартный proxy AppDelegate для FCM |
| `NSAppTransportSecurity → NSAllowsArbitraryLoadsInWebContent` | `true` | сайты в WKWebView могут грузить mixed-content |
| `LSApplicationQueriesSchemes` | `https,http,tel,mailto` | внешние ссылки открываются через `url_launcher` |

### 8.3. Entitlements / privacy

- `ios/Runner/Runner.entitlements` — `aps-environment = development`. На
  релизном профиле автоматически становится `production`.
- `ios/Runner/PrivacyInfo.xcprivacy` — собственный набор required-reason API
  и `NSPrivacyTrackingDomains` (AppsFlyer / Firebase). Включён в Runner
  bundle через `Resources` build phase.

### 8.4. AppsFlyer / Firebase / FCM

- AppsFlyer iOS dev key и Firebase project number зашиты в виде
  обфусцированных байтов в `lib/gray/config/runtime_brand.dart`. Для
  смены значений: положить плейн-значения в `tool/encode_keys.dart`,
  выполнить `dart run tool/encode_keys.dart`, скопировать массивы в
  `_installKeyIos` / `_firebaseProjectIos`, очистить `tool/encode_keys.dart`.
- ATT-prompt вызывается до `initSdk` с задержкой ~700 мс (см.
  `_requestAttPrompt` в `install_signal_client.dart`). При первом запуске
  пользователь увидит системный диалог трекинга.
- В `pulse_dispatch.dart` перед `getToken()` ждём APNs-токен (`_apnsRetries`
  попыток × `_apnsBackoff`). Это снимает кейс пустого FCM-токена при
  холодном старте на TestFlight.

### 8.5. WKWebView нюансы

- `BrowserShell` создаётся через `WebKitWebViewControllerCreationParams` с
  `allowsInlineMediaPlayback: true`, чтобы видео не уходило в полноэкранный
  плеер iOS.
- На iOS включены `setAllowsBackForwardNavigationGestures(true)` (свайпы
  вперёд / назад) и инжект `__tfCamShim`, который вычищает атрибуты
  `capture` / агрессивный `accept` у `<input type=file>` и блокирует
  `navigator.mediaDevices.getUserMedia`. Это позволяет жить без
  `NSCameraUsageDescription`.

### 8.6. Codemagic checklist (gray)

1. Workflow `iOS App Store` → **Environment**:
   - File: `GoogleService-Info.plist` → mount path `ios/Runner/GoogleService-Info.plist`.
2. **iOS code signing**:
   - App Store Connect API key (Issuer ID, Key ID, .p8 — роль `App Manager`).
   - Bundle id `com.tstudiomgames.towerfalls`.
3. **Build** → перед `flutter build ipa` добавьте шаг `flutter pub get` и
   `pod install` (Codemagic делает это автоматически в шаблоне Flutter).
4. **Distribution** → App Store Connect → `Submit to TestFlight beta review`.

### 8.7. Если ATT-prompt не появился в TestFlight

- ATT prompt показывается строго **один раз** на установку. После выбора
  вариант хранится в системе.
- Сбросить: на устройстве Settings → Privacy & Security → Tracking →
  Allow Apps to Request to Track → выключить и снова включить, либо
  удалить приложение и поставить заново.
- Проверить, что в `Info.plist` присутствует `NSUserTrackingUsageDescription`
  и что `Privacy Manifest` не запрещает трекинг.
