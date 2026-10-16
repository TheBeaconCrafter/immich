# Fork notes

This fork of Immich adds features to the mobile app. Each feature is kept in its own files, so pulling upstream
changes means touching only a few marked lines (search for `fork:`).

## Ultra HDR photos (Android and iOS)

When you open an HDR photo in the asset viewer, it is shown with its full brightness range, like Google Photos
and Apple Photos. Bright highlights go above SDR white, and the display ramps its brightness up and down as you
enter and leave the photo.

Supported formats:

- Ultra HDR / ISO 21496-1 gain-map JPEGs (Pixel, Samsung and other Android 14+ cameras)
- Apple gain-map HEIC/JPEG (iPhone 12 and later)
- 10-bit HLG/PQ stills on Android

### Requirements

- **Android 14 or later** with an HDR-capable display.
- **iOS 17 or later** with an EDR-capable display. ISO 21496-1 (Android-made Ultra HDR) photos need **iOS 18**; older
  XMP-only Ultra HDR files may show as SDR on iOS 17.
- On other devices nothing changes.

### How it works

Flutter renders everything into an SDR surface, and Flutter's `Image` cannot output HDR on either platform as of
Flutter 3.47. So HDR photos are drawn by a native view placed exactly on top of the normal Flutter image:

| Part | File |
| --- | --- |
| Dart overlay. It mirrors the PhotoView zoom/pan transform, is created only for the page in view, and removes itself for SDR photos. | `mobile/lib/presentation/widgets/asset_viewer/hdr_image_overlay.widget.dart` |
| Android: an `ImageView` in a hybrid-composition platform view. The window switches to `COLOR_MODE_HDR` while an HDR photo is on screen. | `mobile/android/app/src/main/kotlin/app/alextran/immich/hdr/` |
| iOS: a `UIImageView` with `preferredImageDynamicRange = .high`. Decoding uses ImageIO's `kCGImageSourceDecodeToHDR` on iOS 18 and `UIImageReader` on iOS 17. | `mobile/ios/Runner/Core/Hdr/HdrImagePlugin.swift` |
| Setting: *Settings → Asset viewer → Display HDR photos* (on by default). | `mobile/lib/widgets/settings/asset_viewer_settings/image_viewer_hdr_setting.dart` |

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

### Upstream touch points

These are the only edits to upstream files:

- `MainActivity.kt` and `AppDelegate.swift`: register the plugin (one line each).
- `asset_page.widget.dart`: adds the overlay to the page's `Stack`.
- `settings_key.dart`, `image_config.dart` and `app_config.dart`: add the `imageHdr` setting.
- `asset_viewer_settings.dart`: lists the setting tile.

The setting's strings are hard-coded English, so there are no edits to `i18n/en.json`.

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
