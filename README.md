<div align="center">

<img src="assets/logo.svg" alt="NexusBot" width="96" />

# NexusBot — Flutter App

**The official cross-platform client for the [NexusBot](https://github.com/yosefyosef13054/NEXUSBOT) AI chat backend.**

A production-grade Flutter front end for multi-session AI chat — real-time token streaming, document-grounded answers (RAG), tool calling, and JWT auth — with one adaptive UI that runs on **iOS, Android, web, macOS, Windows, and Linux**.

[![Flutter](https://img.shields.io/badge/Flutter-3.24+-0A0A0A?style=for-the-badge&logo=flutter&logoColor=EF4444&labelColor=0A0A0A)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.5+-0A0A0A?style=for-the-badge&logo=dart&logoColor=EF4444&labelColor=0A0A0A)](https://dart.dev)
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
- ⚡ **Real-time streaming** — assistant replies render token-by-token over **SSE** (default) or **WebSocket** (toggle in settings).
- 📚 **RAG toggle** — ground answers in your uploaded documents; inline citations show which source each answer came from.
- 🛠 **Tools toggle** — let the backend agent call tools (calculator, web search, DB lookups); tool calls surface live in the transcript.
- 🔐 **JWT auth** — register / login, tokens stored in the platform secure store, with **transparent access-token refresh** on `401`.
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
| **Navigation** | `go_router` (`core/router.dart`) | Declarative routes with a redirect that bounces unauthenticated users to **/login** and authenticated users away from auth screens. |
| **HTTP** | `dio` (`core/api_client.dart`) | One client injects `Authorization: Bearer <jwt>` on every request. An interceptor catches `401`, **refreshes the access token** with the refresh token, retries the original request, and only fails if the refresh itself fails. Backend error envelopes are mapped to a typed `ApiException`. |
| **Streaming** | `flutter_client_sse` + `web_socket_channel` | `ChatRepository.streamMessage` picks the transport; both emit the same `StreamEvent` types so the controller doesn't care which is active. |
| **Secrets** | `flutter_secure_storage` | Access + refresh tokens live in Keychain / Keystore, never in plain prefs. |
| **Preferences** | `shared_preferences` (`core/preferences.dart`) | Theme mode, transport (SSE/WS), model, streaming on/off, RAG-by-default. |
| **Theming** | `core/theme.dart` + `google_fonts` | Crimson brand tokens, dark/light, spacing / radius scales. |
| **Adaptive layout** | `core/breakpoints.dart` + `shared/home_shell.dart` | `< 720` → drawer; `≥ 720` → persistent sidebar; `≥ 1100` → desktop spacing. |

### The streaming wire format

Both SSE and WebSocket deliver the same discriminated events (parsed by the sealed `StreamEvent` in `features/chat/chat_models.dart`):

```jsonc
{ "type": "user_message",      "data": { "id": "…", "content": "…" } }
{ "type": "citations",         "data": [ { "document_name": "spec.pdf", "score": 0.84, "excerpt": "…" } ] }
{ "type": "token",             "data": "Hel" }
{ "type": "token",             "data": "lo" }
{ "type": "tool_call",         "data": { "tool": "calculator", "input": "…", "output": "…" } }
{ "type": "usage",             "data": { "prompt_tokens": 1240, "completion_tokens": 312 } }
{ "type": "done",              "data": { "text": "Hello!", "latency_ms": 820 } }
{ "type": "assistant_message", "data": { "id": "…", "content": "Hello!", "citations": […] } }
```

The chat controller appends `token` events to a live buffer, swaps in `citations` / `tool_call` events as they arrive, and replaces the bubble with the canonical `assistant_message` when the stream completes.

---

## 🧰 Tech stack

| Area | Packages |
|---|---|
| State management | `flutter_riverpod` |
| Routing | `go_router` |
| Networking | `dio`, `flutter_client_sse`, `web_socket_channel` |
| Persistence | `flutter_secure_storage`, `shared_preferences` |
| UI | `google_fonts`, `flutter_svg`, `flutter_markdown`, `markdown` |
| Utilities | `intl`, `uuid`, `file_picker`, `collection` |
| Tooling | `flutter_lints`, `flutter_launcher_icons` |

---

## 🚀 Getting started

### Prerequisites

- **Flutter SDK 3.24+** (Dart 3.5+) — `flutter doctor` should be green for your target platform.
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
| Tools by default | per-chat composer toggle | On |

The app has **no embedded secrets** — authentication is entirely token-based against the backend.

---

## 📁 Project structure

```
lib/
├─ main.dart                 # Entry point — ProviderScope + bootstrap
├─ app.dart                  # MaterialApp.router + theme wiring
├─ core/
│  ├─ api_client.dart        # Dio client + JWT-refresh interceptor + ApiException
│  ├─ env.dart               # API_BASE_URL / WS URL / USE_WEBSOCKET (dart-define)
│  ├─ router.dart            # go_router routes + auth redirect
│  ├─ secure_storage.dart    # Token storage (Keychain / Keystore)
│  ├─ preferences.dart       # SharedPreferences-backed app settings
│  ├─ theme.dart             # Brand colors, typography, spacing tokens
│  ├─ breakpoints.dart       # Adaptive layout breakpoints
│  └─ widgets.dart           # Shared UI primitives
├─ features/
│  ├─ auth/                  # login · register · splash · repository · providers
│  ├─ chat/                  # chat screen · controller · repository · models · SSE/WS · code blocks
│  ├─ documents/             # upload + ingest-status list
│  └─ settings/              # theme · transport · model · streaming · RAG
└─ shared/
   ├─ home_shell.dart        # Adaptive drawer (mobile) / sidebar (wide) shell
   └─ sidebar.dart           # Session list, search, new chat, profile
```

---

## 🏷 App icon

The launcher icon is generated for all platforms with `flutter_launcher_icons` from `assets/icon/app_icon.png` (a crimson NexusBot mark). To regenerate after changing the source image:

```bash
dart run flutter_launcher_icons
```

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
