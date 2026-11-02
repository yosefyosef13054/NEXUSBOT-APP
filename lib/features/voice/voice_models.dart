/// One voice of the text-to-speech provider (`GET /audio/voices`).
class VoiceInfo {
  const VoiceInfo({required this.id, required this.name});

  factory VoiceInfo.fromJson(Map<String, dynamic> j) => VoiceInfo(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? (j['id'] as String?) ?? '',
      );

  final String id;
  final String name;
}

/// What speech features the server offers (`GET /audio/voices`). The
/// microphone is shown only with [sttAvailable]; "speak replies" only with
/// [ttsAvailable].
class VoiceCapabilities {
  const VoiceCapabilities({
    required this.provider,
    required this.sttAvailable,
    required this.ttsAvailable,
    this.defaultVoice,
    this.defaultFormat,
    this.voices = const [],
  });

  factory VoiceCapabilities.fromJson(Map<String, dynamic> j) => VoiceCapabilities(
        provider: (j['provider'] as String?) ?? 'none',
        sttAvailable: j['stt_available'] == true,
        ttsAvailable: j['tts_available'] == true,
        defaultVoice: j['default_voice'] as String?,
        defaultFormat: j['default_format'] as String?,
        voices: (j['voices'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => VoiceInfo.fromJson(m.cast<String, dynamic>()))
            .where((v) => v.id.isNotEmpty)
            .toList(),
      );

  /// No speech provider at all (also what an older server resolves to).
  static const none = VoiceCapabilities(provider: 'none', sttAvailable: false, ttsAvailable: false);

  /// `openai` | `fake` | `none`.
  final String provider;
  final bool sttAvailable;
  final bool ttsAvailable;
  final String? defaultVoice;

  /// `mp3` | `wav` | … — the format spoken replies use unless overridden.
  final String? defaultFormat;
  final List<VoiceInfo> voices;

  bool get any => sttAvailable || ttsAvailable;

  /// Display name for a voice id, falling back to the id.
  String labelFor(String? id) {
    if (id == null) return 'Server default';
    for (final v in voices) {
      if (v.id == id) return v.name;
    }
    return id;
  }
}

/// `POST /audio/transcriptions`.
class Transcription {
  const Transcription({
    required this.text,
    required this.provider,
    this.language,
    this.durationSeconds,
  });

  factory Transcription.fromJson(Map<String, dynamic> j) => Transcription(
        text: (j['text'] as String?) ?? '',
        language: j['language'] as String?,
        durationSeconds: (j['duration_seconds'] as num?)?.toDouble(),
        provider: (j['provider'] as String?) ?? '',
      );

  final String text;
  final String? language;
  final double? durationSeconds;
  final String provider;
}

/// `POST /sessions/{id}/messages/voice` → 202: the clip was transcribed and
/// the turn runs in the background. Attach to [generationId] through the
/// generation event replay; the transcript is the user message's text.
class VoiceTurn {
  const VoiceTurn({
    required this.generationId,
    required this.transcript,
    required this.userMessageId,
    this.attachmentId,
  });

  factory VoiceTurn.fromJson(Map<String, dynamic> j) => VoiceTurn(
        generationId: (j['generation_id'] as String?) ?? '',
        transcript: (j['transcript'] as String?) ?? '',
        userMessageId: (j['user_message_id'] as String?) ?? '',
        attachmentId: j['attachment_id'] as String?,
      );

  final String generationId;
  final String transcript;
  final String userMessageId;

  /// The clip, stored as an `audio` attachment of the user message.
  final String? attachmentId;
}
