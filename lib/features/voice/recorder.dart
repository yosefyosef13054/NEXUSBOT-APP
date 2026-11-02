import 'dart:io' show File;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// A finished recording, ready to upload.
class RecordedClip {
  const RecordedClip({
    required this.bytes,
    required this.mimeType,
    required this.filename,
    this.duration,
  });

  final Uint8List bytes;
  final String mimeType;

  /// `voice.m4a` / `voice.wav` / `voice.webm` — the server sniffs the format
  /// from the bytes, the extension is only a hint.
  final String filename;
  final Duration? duration;

  bool get isEmpty => bytes.isEmpty;
}

/// Microphone capture behind an interface, so the push-to-talk flow can be
/// tested without a device. See [RecordPackageRecorder].
abstract class Recorder {
  /// Whether this platform can record at all.
  bool get isSupported;
  bool get isRecording;

  /// Asks for the microphone permission (prompting when needed).
  Future<bool> hasPermission();

  /// Starts capturing; throws when the microphone is unavailable.
  Future<void> start();

  /// Stops and returns the clip, or null when nothing was captured.
  Future<RecordedClip?> stop();

  /// Discards the current recording.
  Future<void> cancel();

  Future<void> dispose();
}

/// [Recorder] on top of the `record` package: AAC in an M4A container where
/// the platform supports it (iOS, Android, macOS), WAV otherwise, Opus/WebM
/// in the browser — all formats the server accepts.
class RecordPackageRecorder implements Recorder {
  /// The `record` plugin is created on first use: its constructor already
  /// talks to the platform, which has no business happening at app start.
  RecordPackageRecorder({AudioRecorder Function()? createRecorder})
      : _createRecorder = createRecorder ?? AudioRecorder.new;

  final AudioRecorder Function() _createRecorder;
  AudioRecorder? _instance;
  DateTime? _startedAt;
  String? _path;
  _Format? _format;

  AudioRecorder get _recorder => _instance ??= _createRecorder();

  @override
  bool get isSupported => true;

  @override
  bool get isRecording => _startedAt != null;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> start() async {
    if (isRecording) return;
    final format = await _pickFormat();
    final path = await _tempPath(format);
    await _recorder.start(
      RecordConfig(encoder: format.encoder, sampleRate: 44100, numChannels: 1),
      path: path,
    );
    _format = format;
    _path = path;
    _startedAt = DateTime.now();
  }

  @override
  Future<RecordedClip?> stop() async {
    if (!isRecording) return null;
    final startedAt = _startedAt!;
    final format = _format!;
    _startedAt = null;
    final result = await _recorder.stop();
    final location = result ?? _path;
    _path = null;
    if (location == null) return null;
    final bytes = await _readBytes(location);
    if (bytes.isEmpty) return null;
    return RecordedClip(
      bytes: bytes,
      mimeType: format.mimeType,
      filename: 'voice.${format.extension}',
      duration: DateTime.now().difference(startedAt),
    );
  }

  @override
  Future<void> cancel() async {
    _startedAt = null;
    _path = null;
    await _recorder.cancel();
  }

  @override
  Future<void> dispose() async {
    final instance = _instance;
    _instance = null;
    _startedAt = null;
    if (instance != null) await instance.dispose();
  }

  Future<_Format> _pickFormat() async {
    if (kIsWeb) return _Format.webm;
    if (await _recorder.isEncoderSupported(AudioEncoder.aacLc)) return _Format.m4a;
    return _Format.wav;
  }

  Future<String> _tempPath(_Format format) async {
    final name = 'nexusbot-voice-${DateTime.now().millisecondsSinceEpoch}.${format.extension}';
    if (kIsWeb) return name; // ignored by the web implementation
    final dir = await getTemporaryDirectory();
    return '${dir.path}/$name';
  }

  /// On IO platforms the recorder wrote a file; in the browser it returns a
  /// `blob:` URL that must be fetched.
  Future<Uint8List> _readBytes(String location) async {
    if (kIsWeb || location.startsWith('blob:')) {
      final res = await Dio().get<List<int>>(
        location,
        options: Options(responseType: ResponseType.bytes),
      );
      final data = res.data ?? const <int>[];
      return data is Uint8List ? data : Uint8List.fromList(data);
    }
    final file = File(location);
    final bytes = await file.readAsBytes();
    try {
      await file.delete();
    } catch (_) {
      // Temp file; the OS reclaims it eventually.
    }
    return bytes;
  }
}

enum _Format {
  m4a(AudioEncoder.aacLc, 'audio/mp4', 'm4a'),
  wav(AudioEncoder.wav, 'audio/wav', 'wav'),
  webm(AudioEncoder.opus, 'audio/webm', 'webm');

  const _Format(this.encoder, this.mimeType, this.extension);
  final AudioEncoder encoder;
  final String mimeType;
  final String extension;
}

final recorderProvider = Provider<Recorder>((ref) {
  final recorder = RecordPackageRecorder();
  ref.onDispose(recorder.dispose);
  return recorder;
});
