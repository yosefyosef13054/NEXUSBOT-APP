import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'env.dart';

/// Streaming transport for assistant replies.
enum StreamTransport { sse, websocket }

/// User preferences persisted to SharedPreferences.
///
/// Single source of truth for app-level settings (theme, transport, model,
/// streaming toggle, RAG / tools defaults). Every screen reads through the
/// Riverpod providers below; no direct SharedPreferences calls elsewhere.
class AppPrefs {
  const AppPrefs({
    required this.themeMode,
    required this.transport,
    required this.model,
    required this.streamingEnabled,
    required this.ragByDefault,
    required this.toolsByDefault,
    this.speakReplies = false,
    this.voice,
    this.activeOrgId,
    this.activeOrgUserId,
  });

  final ThemeMode themeMode;
  final StreamTransport transport;
  final String model;
  final bool streamingEnabled;
  final bool ragByDefault;
  final bool toolsByDefault;

  /// Ask for a spoken reply (`voice_reply`) on every typed send. Only offered
  /// when the server has text-to-speech (`GET /audio/voices`).
  final bool speakReplies;

  /// Voice id for spoken replies (`GET /audio/voices`); null = server default.
  final String? voice;

  /// The organization the app acts in (`X-Org-Id`); null = the personal
  /// workspace. Stored together with the user it was chosen by
  /// ([activeOrgUserId]) so another account on the same device never
  /// inherits it — read it through [activeOrgIdFor].
  final String? activeOrgId;
  final String? activeOrgUserId;

  /// The active organization chosen by [userId], or null (personal).
  String? activeOrgIdFor(String userId) => activeOrgUserId == userId ? activeOrgId : null;

  AppPrefs copyWith({
    ThemeMode? themeMode,
    StreamTransport? transport,
    String? model,
    bool? streamingEnabled,
    bool? ragByDefault,
    bool? toolsByDefault,
    bool? speakReplies,
    String? voice,
    bool clearVoice = false,
    String? activeOrgId,
    String? activeOrgUserId,
    bool clearActiveOrg = false,
  }) =>
      AppPrefs(
        themeMode: themeMode ?? this.themeMode,
        transport: transport ?? this.transport,
        model: model ?? this.model,
        streamingEnabled: streamingEnabled ?? this.streamingEnabled,
        ragByDefault: ragByDefault ?? this.ragByDefault,
        toolsByDefault: toolsByDefault ?? this.toolsByDefault,
        speakReplies: speakReplies ?? this.speakReplies,
        voice: clearVoice ? null : (voice ?? this.voice),
        activeOrgId: clearActiveOrg ? null : (activeOrgId ?? this.activeOrgId),
        activeOrgUserId: clearActiveOrg ? null : (activeOrgUserId ?? this.activeOrgUserId),
      );

  static const defaults = AppPrefs(
    themeMode: ThemeMode.system,
    transport: StreamTransport.sse,
    model: 'gpt-4o-mini',
    streamingEnabled: true,
    ragByDefault: true,
    toolsByDefault: true,
  );
}

class _PrefKeys {
  static const themeMode = 'pref.themeMode';
  static const transport = 'pref.transport';
  static const model = 'pref.model';
  static const streaming = 'pref.streaming';
  static const rag = 'pref.rag';
  static const tools = 'pref.tools';
  static const speakReplies = 'pref.speakReplies';
  static const voice = 'pref.voice';
  static const activeOrg = 'pref.activeOrgId';
  static const activeOrgUser = 'pref.activeOrgUserId';
}

class PrefsController extends StateNotifier<AppPrefs> {
  PrefsController(this._prefs) : super(_read(_prefs));

  final SharedPreferences _prefs;

  static AppPrefs _read(SharedPreferences p) => AppPrefs(
        themeMode: ThemeMode.values[p.getInt(_PrefKeys.themeMode) ?? ThemeMode.system.index],
        // `--dart-define=USE_WEBSOCKET=true` picks the default; Settings wins.
        transport: StreamTransport.values[p.getInt(_PrefKeys.transport) ??
            (Env.useWebSocketStreaming ? StreamTransport.websocket : StreamTransport.sse).index],
        model: p.getString(_PrefKeys.model) ?? AppPrefs.defaults.model,
        streamingEnabled: p.getBool(_PrefKeys.streaming) ?? true,
        ragByDefault: p.getBool(_PrefKeys.rag) ?? true,
        toolsByDefault: p.getBool(_PrefKeys.tools) ?? true,
        speakReplies: p.getBool(_PrefKeys.speakReplies) ?? false,
        voice: p.getString(_PrefKeys.voice),
        activeOrgId: p.getString(_PrefKeys.activeOrg),
        activeOrgUserId: p.getString(_PrefKeys.activeOrgUser),
      );

  Future<void> setThemeMode(ThemeMode m) async {
    state = state.copyWith(themeMode: m);
    await _prefs.setInt(_PrefKeys.themeMode, m.index);
  }

  Future<void> setTransport(StreamTransport t) async {
    state = state.copyWith(transport: t);
    await _prefs.setInt(_PrefKeys.transport, t.index);
  }

  Future<void> setModel(String model) async {
    state = state.copyWith(model: model);
    await _prefs.setString(_PrefKeys.model, model);
  }

  Future<void> setStreaming(bool v) async {
    state = state.copyWith(streamingEnabled: v);
    await _prefs.setBool(_PrefKeys.streaming, v);
  }

  Future<void> setRag(bool v) async {
    state = state.copyWith(ragByDefault: v);
    await _prefs.setBool(_PrefKeys.rag, v);
  }

  Future<void> setTools(bool v) async {
    state = state.copyWith(toolsByDefault: v);
    await _prefs.setBool(_PrefKeys.tools, v);
  }

  Future<void> setSpeakReplies(bool v) async {
    state = state.copyWith(speakReplies: v);
    await _prefs.setBool(_PrefKeys.speakReplies, v);
  }

  /// Voice for spoken replies; null restores the server default.
  Future<void> setVoice(String? voice) async {
    state = state.copyWith(voice: voice, clearVoice: voice == null);
    if (voice == null) {
      await _prefs.remove(_PrefKeys.voice);
    } else {
      await _prefs.setString(_PrefKeys.voice, voice);
    }
  }

  /// Remembers the organization [userId] works in; null = their personal
  /// workspace (no `X-Org-Id` header).
  Future<void> setActiveOrg({required String userId, required String? orgId}) async {
    if (orgId == null) {
      state = state.copyWith(clearActiveOrg: true);
      await _prefs.remove(_PrefKeys.activeOrg);
      await _prefs.remove(_PrefKeys.activeOrgUser);
      return;
    }
    state = state.copyWith(activeOrgId: orgId, activeOrgUserId: userId);
    await _prefs.setString(_PrefKeys.activeOrg, orgId);
    await _prefs.setString(_PrefKeys.activeOrgUser, userId);
  }
}

/// Per-chat preferences that live on this device only (keyed by session id).
///
/// Currently the tool selection made in the chat's tool picker. Reads go
/// through the same SharedPreferences instance as [AppPrefs].
class SessionPrefs {
  SessionPrefs(this._prefs);
  final SharedPreferences _prefs;

  static String _toolsKey(String sessionId) => 'pref.session.$sessionId.toolNames';

  /// The tools picked for [sessionId], or null when the user never changed
  /// the default selection.
  List<String>? toolNames(String sessionId) => _prefs.getStringList(_toolsKey(sessionId));

  /// Persists the picker's selection; null restores the default.
  Future<void> setToolNames(String sessionId, List<String>? names) async {
    if (names == null) {
      await _prefs.remove(_toolsKey(sessionId));
    } else {
      await _prefs.setStringList(_toolsKey(sessionId), names);
    }
  }
}

final sharedPreferencesProvider = FutureProvider<SharedPreferences>((_) {
  return SharedPreferences.getInstance();
});

final sessionPrefsProvider = Provider<SessionPrefs>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider).valueOrNull;
  return SessionPrefs(prefs ?? _DummyPrefs());
});

final prefsProvider = StateNotifierProvider<PrefsController, AppPrefs>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider).valueOrNull;
  if (prefs == null) {
    // Synchronous fallback while SharedPreferences loads — uses defaults; the
    // listener below swaps in real prefs when available.
    return PrefsController(_DummyPrefs());
  }
  return PrefsController(prefs);
});

/// Shim used only until SharedPreferences resolves (≈ a frame at cold start).
class _DummyPrefs implements SharedPreferences {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
