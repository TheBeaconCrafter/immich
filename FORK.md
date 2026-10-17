# Fork notes

This fork of Immich adds features to the mobile app. Each feature is kept in its own files, so pulling upstream
changes means touching only a few marked lines (search for `fork:`).

## Ultra HDR photos (Android and iOS)

When you open an HDR photo in the asset viewer, it is shown with its full brightness range, like Google Photos
and Apple Photos. Bright highlights go above SDR white, and the display ramps its brightness up and down as you
enter and leave the photo.

Supported formats:

- Ultra HDR / ISO 21496-1 gain-map JPEGs (Pixel, Samsung and other Android 14+ cameras)
- Apple gain-map HEIC/JPEG (iPhone 12 and later). On Android this needs the ISO 21496-1 gain map that iOS 18+
  writes alongside Apple's own.
- 10-bit HLG/PQ stills on Android

### Requirements

- **Android 14 or later** with an HDR-capable display.
- **iOS 17 or later** with an EDR-capable display. ISO 21496-1 (Android-made Ultra HDR) photos need **iOS 18**; older
  XMP-only Ultra HDR files may show as SDR on iOS 17.
- On other devices nothing changes.

### How it works

Flutter renders everything into an SDR surface, and Flutter's `Image` cannot output HDR on either platform as of
Flutter 3.47. So HDR photos are drawn natively, exactly where the normal Flutter image is:

| Part | File |
| --- | --- |
| Dart overlay. It mirrors the PhotoView zoom/pan transform, is active only for the page in view, and steps aside for SDR photos. | `mobile/lib/presentation/widgets/asset_viewer/hdr_image_overlay.widget.dart` |
| Android: an `ImageView` in the activity window, *below* a transparent Flutter surface. Flutter clears the photo area once the HDR rendition is drawn and streams the photo's on-screen rect every frame. The window switches to `COLOR_MODE_HDR` while an HDR photo is on screen. | `mobile/android/app/src/main/kotlin/app/alextran/immich/hdr/` |
| iOS: a `UIImageView` with `preferredImageDynamicRange = .high`. Decoding uses ImageIO's `kCGImageSourceDecodeToHDR` on iOS 18 and `UIImageReader` on iOS 17. | `mobile/ios/Runner/Core/Hdr/HdrImagePlugin.swift` |
| Setting: *Settings → Experimental → Display HDR photos* (on by default). | `mobile/lib/widgets/settings/experimental_settings.dart` |

Behaviour:

- **Gestures are unchanged.** The Flutter viewer keeps handling them; the native view ignores touches.
- **Gain maps come from the original file.** Server previews don't keep them.
  - Photos on the device are read straight from the photo library.
  - Remote photos download their original (`/assets/:id/original`). Originals are cached on disk: 512 MB on
    Android, and the shared 1 GB URL cache on iOS.
- **Only likely HDR formats are fetched:** `jpg`, `jpeg`, `heic`, `heif`, `hif` and `avif`. A photo that turns out to
  be SDR is remembered for the rest of the session and not fetched again.
- **Decoding is capped at 4096 px on the long edge** to keep memory in check.
- **The SDR UI around the photo dims while HDR is showing** (Android). This is how the system displays HDR, and
  Google Photos does the same.

#### Preloading on Android

Decoded HDR photos are kept in a memory cache (about 10% of RAM, at most 512 MB). When you land on a photo, the
previous and next ones are decoded in the background, so swiping shows them in HDR right away. Each visible page
has its own native layer, so both photos stay HDR mid-swipe.

#### iPhone HEIC photos on Android

Android decodes the base image of iPhone HEIC photos but ignores their gain map. Two problems have to be solved:

- **Finding the gain map.** `HeifGainmap.kt` parses the HEIF container, finds the ISO 21496-1 `tmap` item, reads
  its metadata and the gain map image it references, and attaches the result to the decoded photo as an Android
  `Gainmap`.
- **Decoding it.** Apple encodes the gain map as a grid of monochrome HEVC tiles (Range Extensions profile), which
  no Android HEVC decoder supports. They are decoded with a bundled copy of
  [libde265](https://github.com/strukturag/libde265) (LGPL-3.0), built by `fork.gradle` from
  `mobile/android/hdr-native/` into `libhdr_native.so`. A 12 MP gain map takes about 150 ms.

#### Why not a Flutter platform view on Android?

The first version embedded the `ImageView` as a hybrid-composition platform view. That made the viewer janky,
because hybrid composition reroutes all of Flutter's rendering through image readers and merges threads while the
view exists, and it still didn't show HDR. Drawing the photo in the window itself avoids platform views entirely.

The cost is that on HDR-capable Android devices (Android 14+, display reports HDR headroom, setting on), Flutter
renders into a transparent surface above the window. Other devices keep upstream's opaque surface. Toggling the
setting takes effect on Android after an app restart.

HDR videos (iPhone Dolby Vision/HLG, Pixel HDR) play from the original file on Android HDR displays when the HDR
video setting is on: the server's transcodes are tone-mapped to SDR. This uses more data than the transcode.

While you drag a photo down to dismiss it, the normal Flutter image takes over, and the HDR one comes back if you
let go.

### Upstream touch points

These are the only edits to upstream files:

- `MainActivity.kt`: registers the plugin and picks the background/render mode (`getBackgroundMode`,
  `getRenderMode`, `onCreate`).
- `AppDelegate.swift`: registers the plugin (one line).
- `asset_page.widget.dart`: adds the overlay to the page's `Stack`.
- `video_viewer.widget.dart`: plays the original video on Android HDR displays (one line).
- `asset_preloader.dart`: preloads the HDR renditions of the neighbouring photos.
- `settings_key.dart`, `image_config.dart` and `app_config.dart`: add the `imageHdr` setting.

The setting's strings are hard-coded English, so there are no edits to `i18n/en.json`.

## Experimental settings (branch `feat/experimental-settings`)

*Settings → Experimental* collects the fork's toggles:

| Setting | Platforms | Default |
| --- | --- | --- |
| Display HDR photos | Android, iOS | on |
| Material You theming: uses the device's own Material You colors, exactly as Android computes them (including styles such as monochrome), and replaces the primary color option | Android | on |
| Play HDR videos in HDR: plays HDR videos from the original file on HDR displays, as the server's transcodes are SDR | Android | on |
| Predictive back: pages, the photo viewer and the account dialog follow the back gesture | Android | on |
| New search: a bottom search bar with iOS Photos style suggestions that combine as filters (see below) | Android, iOS | off |
| Floating tab bar: a Google Photos style pill with the tabs and a separate round search button | Android | off |

Code: `mobile/lib/widgets/settings/experimental_settings.dart`, `mobile/lib/theme/material_you.dart` and
`mobile/lib/widgets/common/floating_tab_bar.dart`.

Upstream touch points (each marked `fork:`):

- `settings.page.dart`: the Experimental section.
- `settings_key.dart`, `theme_config.dart` and `app_config.dart`: the setting keys.
- `theme.provider.dart`: Material You; `main.dart`: reads the device scheme at startup (one line);
  `MainActivity.kt`: registers `theme/MaterialYouPlugin.kt` (one line); `primary_color_setting.dart`: grays out the
  color option while Material You is on.
- `library.page.dart`: keeps the last entries clear of the floating tab bar.
- `tab_shell.page.dart`: the floating tab bar.
- `AndroidManifest.xml`: opts into predictive back (`enableOnBackInvokedCallback`); `theme_data.dart`: the page
  transitions from `mobile/lib/theme/predictive_back.dart` (one line); `router.dart` and `immich_sliver_app_bar.dart`:
  `PredictiveBackGesture` around the photo viewer and the account dialog.

## Liquid Glass on iOS (branch `feat/ios-liquid-glass`)

On iOS 26 and later, the main navigation and controls use Apple's native Liquid Glass components. Older iOS
versions and Android are unchanged: every component falls back to the regular Flutter widget. *Settings →
Experimental → Liquid Glass* (on by default) turns it off; the choice applies after restarting the app.

| What | How |
| --- | --- |
| Tab bar | A real `UITabBar` in the window, synced with Flutter's tabs over a channel. Flutter reserves its space and hides it whenever another route (viewer, dialog, sheet, page) covers the tab shell. |
| Context menus | Native `UIMenu`s, presented from a hidden UIKit button placed over each Flutter menu trigger. The entries (label, icon, enabled state, action) are read from the `MenuItemButton`s the existing menu builds, so menus are not duplicated. Material icons are rendered to template images. |
| Sheets | `BaseBottomSheet`, the viewer's info sheet and modal bottom sheets (`showGlassModalBottomSheet`) draw on native glass. |
| Viewer | An iOS Photos style toolbar: icon-only buttons, share and delete on glass circles, the favorite button and the other actions on a glass capsule. A round glass back button and glass for the top actions. |
| Other controls | App bar actions, the search field and filter chips, album search and filters, and the library buttons and lists sit on glass. |

Glass surfaces are platform views that never take part in hit testing, so they can sit next to other platform views
such as the video player without stealing touches. Flutter draws content that follows another platform view inside a
glass surface (the map in the info sheet) below the glass; `GlassLift` puts an empty native view behind such content
so it is layered on top.

Code:

- `mobile/ios/Runner/Core/LiquidGlass/LiquidGlassPlugin.swift`: the glass surface platform view, the native menu
  presenter and the native tab bar.
- `mobile/packages/ui/lib/src/fork/liquid_glass.dart`: `GlassSurface`, `GlassCard`, `GlassGroup`, `GlassCircle`,
  `GlassToolbar`, `GlassIconOnly`, `GlassLift`, `glassActions`, `showGlassModalBottomSheet` and `NativeMenuAnchor` (a drop-in for
  `MenuAnchor`).
- `mobile/lib/presentation/widgets/liquid_glass/native_tab_bar.widget.dart`: the Flutter side of the tab bar.

Upstream touch points (each marked `fork:`):

- `AppDelegate.swift`: registers the plugin (one line).
- `main.dart`: reads the setting at startup (one line); `settings_key.dart`, `theme_config.dart` and
  `app_config.dart`: the setting key.
- `tab_shell.page.dart`: uses the native tab bar on iOS 26+.
- `base_bottom_sheet.widget.dart`: `Card` → `GlassCard`; `asset_details.widget.dart` and
  `location_details.widget.dart`: glass info sheet.
- `viewer_top_app_bar.widget.dart`: the favorite button moves to the bottom toolbar.
- `menu_item.dart` (`ImmichMenu`), `trash.page.dart`, `album_option.widget.dart`, `album_selector.widget.dart` and
  `search.page.dart`: `MenuAnchor` → `NativeMenuAnchor`.
- `map.page.dart`, `person.page.dart`, `album_options.page.dart`, `pending_uploads_banner.widget.dart`,
  `primary_color_setting.dart` and `search_filter_utils.dart`: `showModalBottomSheet` → `showGlassModalBottomSheet`.
- `viewer_top_app_bar.widget.dart`, `bottom_bar.widget.dart`, `immich_sliver_app_bar.dart`, `search.page.dart`,
  `search_filter_chip.dart`, `album_selector.widget.dart` and `library.page.dart`: glass behind controls.
- `base_action_button.widget.dart` and `column_button.dart`: icon only inside a `GlassIconOnly` toolbar.
- `immich_sliver_app_bar.dart`: the sync indicator no longer leaves an empty slot once it has faded out.
- `immich_ui.dart`: exports the glass widgets.

## New search (experimental setting)

Typing in the bottom search bar suggests people, cities, regions, countries, camera makes and models, photos or
videos, dates ("2024", "june 2024", "last month"), favorites, tags, text in photos, descriptions, file names and a
search by content. Picking one turns it into a token in the bar; tokens combine, and backspace on an empty field
removes the last one. The chips above the bar list every value of a category. Suggestions show how many assets
match together with the current tokens (from the server's search statistics) and disappear when nothing matches.
On iOS 26+ the bar, chips and suggestions are Liquid Glass.

Code: `mobile/lib/presentation/pages/search/smart/`. Upstream touch point: `search.page.dart` picks the new or the
classic search page (`SearchPage` → `_SearchPage`).

## Building and running

All commands run from the `mobile/` folder. The toolchain (Flutter, Java, Rust) is pinned by mise.

### One-time setup

```bash
brew install mise cocoapods
cd mobile
mise install          # Flutter, Java, Rust in the pinned versions
mise run install      # Dart packages + CocoaPods
mise run codegen      # generated code (API client, translations, Pigeon, ...)
```

If `pod install` fails with an encoding error, run `export LANG=en_US.UTF-8` first.

Give the fork its own identity, so it installs next to the official app (see
[Installing next to the official app](#installing-next-to-the-official-app)):

```bash
scripts/configure-fork.sh --id com.example.immich.hdr --name "Immich HDR" --team ABCDE12345
```

### Android

Connect the phone with USB debugging enabled, then:

```bash
mise exec -- flutter run --release           # build, install and start on the connected phone
mise exec -- flutter build apk --release     # just build: build/app/outputs/flutter-apk/app-release.apk
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Without `android/key.jks` + `android/key.properties`, release builds are signed with this Mac's debug key. Updates
then only install over builds signed with the same key.

HDR needs Android 14+ and an HDR display. `adb logcat | grep -E "HdrHost|HdrCache|HeifGainmap"` shows what the
HDR viewer does.

### iOS

Simulator, no signing needed:

```bash
open -a Simulator
mise exec -- flutter devices                 # find the simulator's name or id
mise exec -- flutter run -d "iPhone 16 Pro"
```

On an iPhone, you need a paid Apple developer team (`--team` above). Connect and unlock the phone, enable
*Developer Mode* (Settings → Privacy & Security), then:

Sign in to Xcode with the team's Apple ID (Xcode → Settings → Accounts). The first build for a new bundle ID has to
let Xcode create the provisioning profiles, which `flutter build` doesn't, so build with `xcodebuild` and install
with `devicectl`:

```bash
xcrun devicectl list devices                 # find the iPhone's id
mise exec -- flutter build ios --release --config-only
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination 'id=<iphone-id>' -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -derivedDataPath build/ios_device build
xcrun devicectl device install app --device <iphone-id> build/ios_device/Build/Products/Release-iphoneos/Immich.app
```

Once the profiles exist, `mise exec -- flutter run -d <iphone-id> --release` works too, and
`mise exec -- flutter build ipa --export-method development` builds an installable `.ipa` in `build/ios/ipa/`.

The simulator runs the app, but HDR brightness needs a real iPhone on iOS 17+ (iOS 18+ for Android-made Ultra HDR).

## Installing next to the official app

You can give the build its own bundle ID and app name, so it installs alongside the official Immich app:

```bash
mobile/scripts/configure-fork.sh --id com.example.immich.hdr --name "Immich HDR" --team ABCDE12345
```

This writes two git-ignored files:

- **`mobile/android/fork.properties`**, read by `mobile/android/app/fork.gradle`.
  - You can also use the environment variables `IMMICH_APP_ID` / `IMMICH_APP_NAME`, or `-P` Gradle properties.
  - Debug builds still append `.debug`. Their launcher label stays "Immich-Debug", because upstream hard-codes it in
    `src/debug/AndroidManifest.xml`; release builds use your name.
- **`mobile/ios/Signing.local.xcconfig`**, read by `mobile/ios/Signing.xcconfig`. It sets:
  - the Runner, Share and Widget bundle IDs
  - the app group (`group.<id>`)
  - your Apple Team ID
  - the home screen name (`IMMICH_DISPLAY_NAME`)

  Debug and Profile builds append `.debug` / `.profile`.

Run `mobile/scripts/configure-fork.sh --reset` to go back to the upstream identifiers.

Then build as usual, for example `flutter build apk --release` or open `mobile/ios/Runner.xcworkspace`.

Caveats when both apps are installed:

- **iOS needs your own paid Apple developer team.** Xcode's automatic signing then registers the new bundle IDs
  and app group. The `applinks:my.immich.app` associated domain only works for the official app; remove it in Xcode if
  provisioning complains.
- **OAuth login:** both apps register the `app.immich://` callback scheme, so the system may ask which app should
  open the login redirect.
