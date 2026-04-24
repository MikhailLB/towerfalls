# Tower Falls — iOS release guide

Бранч: `white-ios-deploy`.

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
  - iPhone orientations: Portrait, LandscapeLeft, LandscapeRight
  - iPad orientations: Portrait, PortraitUpsideDown, LandscapeLeft, LandscapeRight
  - `UIRequiresFullScreen = true` (отключает split view на iPad,
    фиксирует наш лок по ориентации)
  - `UIStatusBarHidden = true`, `UIViewControllerBasedStatusBarAppearance = false`
  - `ITSAppUsesNonExemptEncryption = false` (не используем шифрование за рамками
    стандартного HTTPS, сразу проходит экспортный контроль в App Store Connect)

Ориентации в самом приложении по-прежнему ограничены `SystemChrome`
(главное меню / игра — только `portraitUp`, loading screen —
`portraitUp` + `landscapeLeft/Right`).

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
