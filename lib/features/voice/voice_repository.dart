import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../attachments/attachments_repository.dart';
import '../chat/chat_repository.dart' show ChatRepository;
import 'voice_models.dart';

/// `/audio/*` and the voice-mode turn `POST /sessions/{id}/messages/voice`.
class VoiceRepository {
  VoiceRepository(this._client);
  final ApiClient _client;

  /// Clips above this are refused by the server (25 MB).
  static const maxAudioBytes = 25 * 1024 * 1024;

  /// `GET /audio/voices`.
  Future<VoiceCapabilities> capabilities() async {
    final res = await _client.request<Map<String, dynamic>>('/audio/voices');
    return VoiceCapabilities.fromJson(res.data ?? const {});
  }

  /// `POST /audio/transcriptions` (multipart `file`, optional `language`).
  /// 503 `service_unavailable` / `voice_unavailable` when no STT provider.
  Future<Transcription> transcribe({
    required Uint8List bytes,
    required String filename,
    String? language,
  }) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename),
      if (language != null && language.isNotEmpty) 'language': language,
    });
    final res = await _client.request<Map<String, dynamic>>(
      '/audio/transcriptions',
      method: 'POST',
      data: form,
      options: Options(sendTimeout: const Duration(minutes: 2)),
    );
    return Transcription.fromJson(res.data ?? const {});
  }

  /// `POST /audio/speech {text, voice?, format?}` → the audio bytes
  /// (`audio/mpeg`, `audio/wav`, …).
  Future<AttachmentBytes> speech({required String text, String? voice, String? format}) async {
    final res = await _client.request<List<int>>(
      '/audio/speech',
      method: 'POST',
      data: {
        'text': text,
        if (voice != null) 'voice': voice,
        if (format != null) 'format': format,
      },
      options:
          Options(responseType: ResponseType.bytes, receiveTimeout: const Duration(minutes: 2)),
    );
    final data = res.data ?? const <int>[];
    final mime = res.headers.value('content-type')?.split(';').first.trim();
    return AttachmentBytes(
      bytes: data is Uint8List ? data : Uint8List.fromList(data),
      mimeType: mime == null || mime.isEmpty ? 'audio/mpeg' : mime,
    );
  }

  /// One voice-mode round trip: the clip is transcribed, stored as an `audio`
  /// attachment and the turn starts in the background (→ 202). Attach with
  /// `ChatRepository.resumeGeneration(sessionId, turn.generationId)`; the
  /// `user_message` frame carries the transcript and, with [replyAudio],
  /// `audio_chunk` frames precede the `assistant_message`.
  Future<VoiceTurn> sendVoiceTurn({
    required String sessionId,
    required Uint8List bytes,
    required String filename,
    bool useRag = true,
    bool useTools = true,
    String? model,
    bool replyAudio = true,
    String? voice,
    String? audioFormat,
    String? language,
    String? idempotencyKey,
  }) async {
    if (bytes.isEmpty) {
      throw ApiException(
        code: 'validation_error',
        message: 'Nothing was recorded',
        statusCode: 422,
      );
    }
    if (bytes.length > maxAudioBytes) {
      throw ApiException(code: 'validation_error', message: 'Audio exceeds 25 MB', statusCode: 422);
    }
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename),
      'use_rag': useRag.toString(),
      'use_tools': useTools.toString(),
      'reply_audio': replyAudio.toString(),
      if (model != null) 'model': model,
      if (voice != null) 'voice': voice,
      if (audioFormat != null) 'audio_format': audioFormat,
      if (language != null && language.isNotEmpty) 'language': language,
    });
    final res = await _client.request<Map<String, dynamic>>(
      '/sessions/$sessionId/messages/voice',
      method: 'POST',
      data: form,
      options: Options(
        sendTimeout: const Duration(minutes: 2),
        // Transcription happens before the 202 comes back.
        receiveTimeout: const Duration(minutes: 2),
        headers: {if (idempotencyKey != null) ChatRepository.idempotencyHeader: idempotencyKey},
      ),
    );
    return VoiceTurn.fromJson(res.data ?? const {});
  }
}

final voiceRepositoryProvider = FutureProvider<VoiceRepository>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  return VoiceRepository(client);
});

/// What the server can do with speech. An older server (404) or one without a
/// provider resolves to [VoiceCapabilities.none] instead of an error, so the
/// composer simply shows no microphone.
final voiceCapabilitiesProvider = FutureProvider<VoiceCapabilities>((ref) async {
  final repo = await ref.watch(voiceRepositoryProvider.future);
  try {
    return await repo.capabilities();
  } on ApiException catch (e) {
    if (e.isNotFound || e.statusCode == 503 || e.code == 'service_unavailable') {
      return VoiceCapabilities.none;
    }
    rethrow;
  }
});
