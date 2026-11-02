<div align="center">

<img src="assets/logo.svg" alt="NexusBot" width="96" />

# NexusBot — Flutter App

**The official cross-platform client for the [NexusBot](https://github.com/yosefyosef13054/NEXUSBOT) AI chat backend.**

A production-grade Flutter front end for multi-session AI chat — real-time token streaming, document-grounded answers (RAG), tool calling, and JWT auth — with one adaptive UI that runs on **iOS, Android, web, macOS, Windows, and Linux**.

[![Flutter](https://img.shields.io/badge/Flutter-3.27+-0A0A0A?style=for-the-badge&logo=flutter&logoColor=EF4444&labelColor=0A0A0A)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.6+-0A0A0A?style=for-the-badge&logo=dart&logoColor=EF4444&labelColor=0A0A0A)](https://dart.dev)
[![Riverpod](https://img.shields.io/badge/Riverpod-2.x-0A0A0A?style=for-the-badge&labelColor=0A0A0A)](https://riverpod.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-EF4444?style=for-the-badge&labelColor=0A0A0A)](LICENSE)

</div>

---

## 📱 Screenshots

| Sign in | Chat | Sidebar |
|:---:|:---:|:---:|
| <img src="docs/screenshots/login.png" width="240" /> | <img src="docs/screenshots/chat.png" width="240" /> | <img src="docs/screenshots/sidebar.png" width="240" /> |

---

## ✨ What it is

NexusBot's Flutter app is a thin, well-architected client over the NexusBot REST / SSE / WebSocket API. It owns **no business logic** — every answer, citation, and tool call comes from the backend — so the UI stays simple while the server does the heavy lifting. The same JSON event format is consumed identically over SSE and WebSocket, so the chat experience is transport-agnostic.

### Highlights

- 💬 **Multi-session chat** — create, rename, delete, and full-text search across conversations, with persistent history.
- ⚡ **Real-time streaming** — assistant replies render token-by-token over **SSE** (default) or **WebSocket** (toggle in settings). A **Stop** button interrupts generation; the partial reply is kept and marked *Stopped*.
- 📚 **RAG toggle** — ground answers in your uploaded documents; inline citations show which source each answer came from.
- 🛠 **Tools toggle** — let the backend agent call tools (calculator, web search, DB lookups); tool calls surface live in the transcript.
- 🔐 **JWT auth** — register / login, tokens stored in the platform secure store, with **transparent, single-flight access-token refresh** on `401` (and proactively before a stream opens). Rotating refresh tokens, server-side sign-out, change password, edit display name and delete account.
- 📄 **Document upload** — pick a file, upload, and watch ingest status update.
- 🎨 **Adaptive, branded UI** — a navigation **drawer on mobile** and a **persistent sidebar on tablet/desktop**, dark/light themes, crimson brand, Markdown + syntax-highlighted code blocks.

---

## 🏗 Architecture

The app follows a clean **feature-first** structure with a small shared core. State is managed with **Riverpod**, navigation with **go_router** (including an auth-aware redirect), and all networking flows through a single authenticated **Dio** client.

```
┌──────────────────────────────────────────────────────────┐
│  Screens (features/*/.._screen.dart)                       │  Widgets
├──────────────────────────────────────────────────────────┤
│  Controllers / Providers (Riverpod StateNotifier)          │  UI state
├──────────────────────────────────────────────────────────┤
│  Repositories (auth · chat · documents)                    │  API calls
├──────────────────────────────────────────────────────────┤
│  Core: ApiClient (Dio+JWT) · SSE/WS · SecureStorage · Env  │  Plumbing
└──────────────────────────────────────────────────────────┘
                         │ REST · SSE · WebSocket
                         ▼
                  NexusBot backend (/api/v1)
```

### How the pieces fit

| Concern | Where | Notes |
|---|---|---|
| **State management** | `flutter_riverpod` | `StateNotifier` for live chat state; `FutureProvider` for repositories / session lists. |
| **Navigation** | `go_router` (`core/router.dart`) | Real URLs. A `ShellRoute` keeps the sidebar mounted while `/`, `/chat/:sessionId`, `/documents` and `/settings` swap underneath it; a redirect bounces unauthenticated users to **/login** and authenticated users away from auth screens. A browser refresh on `/chat/<id>` reopens that chat. |
| **HTTP** | `dio` (`core/api_client.dart`) | One client injects `Authorization: Bearer <jwt>` on every request and maps every non-2xx envelope to a typed `ApiException` (with the server's `request_id`). An interceptor catches `401`, refreshes through the **single-flight** `TokenRefresher` (`core/auth_session.dart`) — concurrent 401s await the same refresh — retries once, and only fails if the refresh itself fails. |
| **Streaming** | `dio` (SSE) + `web_socket_channel` | `ChatRepository.streamMessage` opens a `ChatTurn` on the chosen transport; both emit the same `StreamEvent` types so the controller doesn't care which is active. SSE goes through the same Dio client (`ApiClient.openEventStream` + a tiny `core/sse_parser.dart`), so auth refresh applies to streams too. |
| **Secrets** | `flutter_secure_storage` | Access + refresh tokens live in Keychain / Keystore, never in plain prefs. |
| **Preferences** | `shared_preferences` (`core/preferences.dart`) | Theme mode, transport (SSE/WS), model, streaming on/off, RAG-by-default, tools-by-default. |
| **Theming** | `core/theme.dart` + `google_fonts` | Crimson brand tokens, dark/light, spacing / radius scales. |
| **Adaptive layout** | `core/breakpoints.dart` + `shared/home_shell.dart` | `< 720` → drawer; `≥ 720` → persistent sidebar; `≥ 1100` → desktop spacing. |

### Routes

| Location | Screen | Notes |
|---|---|---|
| `/splash` | Splash | Resolves the stored session, then goes to `/` or `/login`. |
| `/login`, `/register` | Auth | Unreachable while signed in. |
| `/` | Landing | Opens the most recent chat automatically, or shows a **New chat** call to action. |
| `/chat/:sessionId` | Chat | Deep-linkable; the sidebar highlights the open session. |
| `/documents` | Documents | Upload + ingest status. |
| `/settings` | Settings | Appearance, chat defaults, model, account. |

Everything below the auth screens lives inside one `ShellRoute` (`shared/home_shell.dart`), so the drawer (mobile) / persistent sidebar (tablet, desktop) never remounts between pages. Sidebar taps and **New chat** simply `context.go(...)`.

### Auth lifecycle

- **Sign in** stores the token pair in secure storage; **Sign out** calls `POST /auth/logout` with the refresh token (best effort) and then clears it locally.
- **Refresh tokens rotate.** Every refresh returns a new pair and the old refresh token dies, so the refresh is single-flight: a burst of `401`s from parallel requests shares one `/auth/refresh` call. A rejected refresh (revoked / reused token) clears the tokens and the router bounces to `/login`.
- Before an SSE or WebSocket stream opens, `ensureFreshAccessToken()` decodes the JWT's `exp` and refreshes if it is within 60 s, so a long reply never dies mid-stream on an expiring token.
- Settings → **Account** exposes display name (`PATCH /auth/me`), change password (`POST /auth/change-password`, keeps this device signed in), sign out everywhere (`POST /auth/logout-all`) and delete account (`DELETE /auth/me`, password-confirmed).

### The streaming wire format

Both SSE and WebSocket deliver the same discriminated events (parsed by the sealed `StreamEvent` in `features/chat/chat_models.dart`):

```jsonc
{ "type": "user_message",      "data": { "id": "…", "content": "…" } }
{ "type": "citations",         "data": [ { "document_name": "spec.pdf", "score": 0.84, "excerpt": "…" } ] }
{ "type": "token",             "data": "Hel" }
{ "type": "token",             "data": "lo" }
{ "type": "tool_call",         "data": { "phase": "end", "tool": "calculator", "input": "…", "output": "…" } }
{ "type": "usage",             "data": { "prompt_tokens": 1240, "completion_tokens": 312, "total_tokens": 1552 } }
{ "type": "done",              "data": { "text": "Hello!", "latency_ms": 820, "interrupted": false } }
{ "type": "assistant_message", "data": { "id": "…", "content": "Hello!", "citations": […], "interrupted": false } }
{ "type": "error",             "data": { "code": "busy", "message": "…" } }
```

The chat controller appends `token` events to a live buffer, swaps in `citations` / `tool_call` events as they arrive, and replaces the bubble with the canonical `assistant_message` when the stream completes. Session titles are generated server-side *after* the stream closes, so the sidebar re-fetches the session list ~2 s after each turn (and on app resume).

**SSE** is a plain `POST …/messages/stream` with `Accept: text/event-stream`, read through Dio as a byte stream and split into `data: <json>` frames by `core/sse_parser.dart`. Cancelling the subscription closes the HTTP connection, which is how **Stop** works on SSE: the server notices the disconnect, persists the partial reply (`meta.status == "interrupted"`), and the app keeps the text it already has.

**WebSocket** connects to `/ws/sessions/{id}` without a token in the URL, sends `{"type":"auth","token":"<jwt>"}` as the first frame and waits for `auth_ok` before sending `user_message`. **Stop** sends `{"type":"stop"}` and keeps listening: the server still emits `done` and `assistant_message`, both with `interrupted: true`. A second `user_message` while one is in flight yields a `busy` error; `ping`/`pong` keep the socket alive.

> **Web note:** Dio's browser adapter delivers an SSE body only once the response completes, so on Flutter **web** pick the **WebSocket** transport for live token streaming.

---

## 🧰 Tech stack

| Area | Packages |
|---|---|
| State management | `flutter_riverpod` |
| Routing | `go_router` |
| Networking | `dio`, `web_socket_channel` |
| Persistence | `flutter_secure_storage`, `shared_preferences` |
| UI | `google_fonts`, `flutter_svg`, `flutter_markdown`, `markdown` |
| Utilities | `intl`, `uuid`, `file_picker`, `collection` |
| Tooling | `flutter_lints`, `flutter_launcher_icons` |

---

## 🚀 Getting started

### Prerequisites

- **Flutter SDK 3.27+** (Dart 3.6+) — `flutter doctor` should be green for your target platform.
- A running **NexusBot backend** (see the [backend repo](https://github.com/yosefyosef13054/NEXUSBOT)). By default the app expects it at `http://localhost:8000/api/v1`.

### Run

```bash
flutter pub get

# Point the app at your backend (defaults to http://localhost:8000/api/v1)
flutter run --dart-define=API_BASE_URL=http://localhost:8000/api/v1
```

### Platform notes for `API_BASE_URL`

| Target | Use |
|---|---|
| iOS Simulator | `http://localhost:8000/api/v1` (App Transport Security already allows local networking) |
| Android Emulator | `http://10.0.2.2:8000/api/v1` (host-loopback alias) |
| Physical device | `http://<your-machine-LAN-IP>:8000/api/v1` |
| Web / macOS / Windows / Linux | `http://localhost:8000/api/v1` |

### Switch streaming transport

SSE is the default. To use WebSocket instead:

```bash
flutter run \
  --dart-define=API_BASE_URL=http://localhost:8000/api/v1 \
  --dart-define=USE_WEBSOCKET=true
```

(Or change it at runtime in **Settings → Streaming transport**.)

### Demo flow

1. **Register** an account (or log in).
2. Tap **New chat**, type a message, and watch the reply stream in.
3. Toggle **RAG** to ground answers in uploaded documents, or **Tools** to let the agent take actions.
4. Upload a document from the **Documents** screen and chat with it.

---

## ⚙️ Configuration

| Setting | How | Default |
|---|---|---|
| `API_BASE_URL` | `--dart-define` at build / run | `http://localhost:8000/api/v1` |
| `USE_WEBSOCKET` | `--dart-define` at build / run | `false` (SSE) |
| Theme (system / light / dark) | Settings screen | System |
| Model | Settings screen | `gpt-4o-mini` |
| Streaming on / off | Settings screen | On |
| RAG by default | Settings screen | On |
| Tools by default | Settings screen (and per-chat composer toggle) | On |

The app has **no embedded secrets** — authentication is entirely token-based against the backend.

---

## 📁 Project structure

```
lib/
├─ main.dart                 # Entry point — ProviderScope + bootstrap
├─ app.dart                  # MaterialApp.router + theme wiring
├─ core/
│  ├─ api_client.dart        # Dio client + single-flight JWT-refresh interceptor + SSE opener
│  ├─ api_exception.dart     # Typed error envelope (code · message · request_id)
│  ├─ auth_session.dart      # TokenRefresher: single-flight refresh + proactive JWT exp check
│  ├─ sse_parser.dart        # Pure-Dart text/event-stream frame decoder
│  ├─ env.dart               # API_BASE_URL / WS URL / USE_WEBSOCKET (dart-define)
│  ├─ router.dart            # go_router shell routes + auth redirect
│  ├─ secure_storage.dart    # Token storage (Keychain / Keystore)
│  ├─ preferences.dart       # SharedPreferences-backed app settings
│  ├─ theme.dart             # Brand colors, typography, spacing tokens
│  ├─ breakpoints.dart       # Adaptive layout breakpoints
│  └─ widgets.dart           # Shared UI primitives
├─ features/
│  ├─ auth/                  # login · register · splash · repository · providers
│  ├─ chat/                  # chat screen · controller · repository (ChatTurn) · models · WS · code blocks
│  ├─ documents/             # upload (de-dup aware) + ingest-progress list
│  └─ settings/              # theme · transport · model · streaming · RAG/tools defaults · account
└─ shared/
   ├─ home_shell.dart        # ShellRoute host: drawer (mobile) / sidebar (wide) + landing route
   └─ sidebar.dart           # Session list, search, new chat, profile (navigates via go_router)
```

---

## 🏷 App icon

The launcher icon is generated for all platforms with `flutter_launcher_icons` from `assets/icon/app_icon.png` (a crimson NexusBot mark). To regenerate after changing the source image:

```bash
dart run flutter_launcher_icons
```

---

## ✅ Continuous integration

`.github/workflows/ci.yml` runs `flutter pub get`, `flutter analyze --fatal-infos --fatal-warnings` and `flutter test` on every push and pull request (Flutter stable via `subosito/flutter-action`). The test suite covers the SSE frame parser, the stream-event parser, the chat reducer (via a fake repository), the token refresher, and an end-to-end check of the API client against a loopback HTTP server.

---

## 🛠 Build for release

```bash
flutter build apk    --dart-define=API_BASE_URL=https://api.yourhost.com/api/v1   # Android
flutter build ipa    --dart-define=API_BASE_URL=https://api.yourhost.com/api/v1   # iOS
flutter build web    --dart-define=API_BASE_URL=https://api.yourhost.com/api/v1   # Web
flutter build macos  --dart-define=API_BASE_URL=https://api.yourhost.com/api/v1   # macOS
```

Use an `https://` backend URL for release builds so the connection isn't blocked by platform transport-security policies.

---

## 📄 License

[MIT](LICENSE) — free for personal and commercial use.

## 🙏 Acknowledgements

Built with [Flutter](https://flutter.dev), [Riverpod](https://riverpod.dev), [go_router](https://pub.dev/packages/go_router), and [Dio](https://pub.dev/packages/dio). Pairs with the [NexusBot backend](https://github.com/yosefyosef13054/NEXUSBOT) (FastAPI + LangChain).
