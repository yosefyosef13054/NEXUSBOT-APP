# Release pipeline (fastlane + GitHub Actions)

Two fastlane setups live next to the platform projects:

| Directory | Lane | What it does |
|---|---|---|
| `android/fastlane` | `build` | `flutter build appbundle --release` with the `API_BASE_URL` / `SENTRY_DSN` dart-defines |
| `android/fastlane` | `internal` | `build` (unless `SKIP_BUILD=1`), then uploads the AAB to the **Play internal testing** track as a draft release |
| `ios/fastlane` | `build` | optional `match` (App Store profile), then `flutter build ipa --release --export-method app-store` |
| `ios/fastlane` | `beta` | `build` (unless `SKIP_BUILD=1`), then uploads the IPA to **TestFlight** through an App Store Connect API key |

`.github/workflows/release.yml` runs on every `v*` tag (and manually): it builds the
Android AAB + APK, an unsigned iOS archive and the web bundle, uploads them as workflow
artifacts, and calls the lanes **only when the matching secrets exist**. `ci.yml`
(analyze + test on every push) is unchanged.

## Local use

```bash
cd android && bundle install && API_BASE_URL=https://api.yourhost.com/api/v1 bundle exec fastlane internal
cd ios     && bundle install && API_BASE_URL=https://api.yourhost.com/api/v1 bundle exec fastlane beta
```

Both lanes expect the Flutter SDK on `PATH` and the environment variables below.

## Required secrets / variables

### Everything

| Name | Where | Notes |
|---|---|---|
| `API_BASE_URL` | repository **variable** (`vars`) | Backend URL baked into every build (`--dart-define`). Falls back to `https://api.example.com/api/v1`. |
| `SENTRY_DSN` | secret, optional | Enables crash reporting in the builds; empty = off. |

### Android — signing + Play Console

| Name | Notes |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 release.keystore`. The workflow decodes it to `android/app/release.keystore` and writes `android/key.properties` (both git-ignored); `app/build.gradle.kts` picks the file up and signs the release build with it. Without it the build is signed with the debug key. |
| `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | Keystore credentials. |
| `PLAY_SERVICE_ACCOUNT_JSON` | The JSON key of a Google Play Console **service account** with the "Release to testing tracks" permission on the app. The workflow writes it to a temp file and points `PLAY_SERVICE_ACCOUNT_JSON_PATH` at it (see `android/fastlane/Appfile`). |
| `ANDROID_PACKAGE_NAME` | Optional env var; defaults to `com.example.nexusbot`. Change `applicationId` in `android/app/build.gradle.kts` for a real release. |

The `internal` lane runs only when **both** the keystore and the service account exist.

### iOS — App Store Connect API key (+ optional match)

| Name | Notes |
|---|---|
| `APP_STORE_CONNECT_API_KEY_ID` | Key id from App Store Connect → Users and Access → Integrations → App Store Connect API. |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer id from the same page. |
| `APP_STORE_CONNECT_API_KEY_CONTENT` | The downloaded `AuthKey_XXXX.p8`, base64-encoded (`base64 -i AuthKey.p8`). |
| `APPLE_TEAM_ID` | Developer team id (also used by `match`). |
| `MATCH_GIT_URL`, `MATCH_PASSWORD` | Optional. When set, the `build` lane runs `match(type: "appstore", readonly: true)` to install the distribution certificate + profile. Otherwise configure automatic signing for the Runner target in Xcode on the machine that builds. |
| `IOS_BUNDLE_ID` | Optional env var; defaults to `com.example.nexusbot`. |

The `beta` lane runs only when `APP_STORE_CONNECT_API_KEY_CONTENT` exists. Signing certificates
are **not** created by the workflow: the unsigned archive is always produced
(`flutter build ipa --no-codesign`) and uploaded as an artifact, which is enough for a
developer to export a signed IPA from Xcode Organizer.

## Store assets that are not in the repository

- Android: a real `applicationId`, the `release.keystore`, Play Console listing (title,
  descriptions, screenshots — the lanes skip metadata uploads).
- iOS: the App Store Connect app record for the bundle id, the share extension target (see
  the README's "Share to NexusBot" section) and the App Privacy answers (the app stores chats
  and attachments on the configured server, no tracking).
