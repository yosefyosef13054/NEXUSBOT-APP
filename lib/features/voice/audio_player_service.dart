// `StreamAudioSource` is the documented way to play audio held in memory; it
// has carried the "experimental" annotation for years and is stable in practice.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

/// An encoded audio clip held in memory (an `audio_chunk` frame, a downloaded
/// spoken reply or the result of `/audio/speech`).
class AudioClip {
  const AudioClip({required this.bytes, required this.mimeType});
  final Uint8List bytes;
  final String mimeType;
}

/// Sequential playback of clips, behind an interface so the chat controller
/// can be tested with a fake. The `audio_chunk` frames of a spoken reply are
/// [enqueue]d as they arrive and play back to back; [play] replaces whatever
/// is queued (replaying a reply's stored clip).
abstract class AudioPlayerService {
  Future<void> enqueue(AudioClip clip);
  Future<void> play(AudioClip clip);
  Future<void> stop();

  /// True while a clip plays or others wait in the queue.
  bool get isPlaying;

  /// Emits whenever [isPlaying] changes.
  Stream<bool> get playingStream;

  Future<void> dispose();
}

/// [AudioPlayerService] on top of `just_audio`. The player is created on
/// first use so merely constructing the service touches no platform channel.
class JustAudioPlayerService implements AudioPlayerService {
  JustAudioPlayerService({AudioPlayer Function()? createPlayer})
      : _createPlayer = createPlayer ?? AudioPlayer.new;

  final AudioPlayer Function() _createPlayer;
  AudioPlayer? _player;
  final _queue = <AudioClip>[];
  final _playing = StreamController<bool>.broadcast();
  bool _draining = false;
  bool _isPlaying = false;
  int _generation = 0;

  @override
  bool get isPlaying => _isPlaying;

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Future<void> enqueue(AudioClip clip) async {
    if (clip.bytes.isEmpty) return;
    _queue.add(clip);
    _setPlaying(true);
    unawaited(_drain());
  }

  @override
  Future<void> play(AudioClip clip) async {
    await stop();
    await enqueue(clip);
  }

  @override
  Future<void> stop() async {
    _generation++;
    _queue.clear();
    final player = _player;
    if (player != null) {
      try {
        await player.stop();
      } catch (_) {
        // Nothing was loaded.
      }
    }
    _setPlaying(false);
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final generation = _generation;
        final clip = _queue.removeAt(0);
        try {
          final player = _player ??= _createPlayer();
          await player.setAudioSource(_BytesAudioSource(clip));
          if (generation != _generation) break;
          // Completes when the clip ends (or playback is stopped).
          await player.play();
        } catch (_) {
          // A broken chunk must not block the ones after it.
        }
        if (generation != _generation) break;
      }
    } finally {
      _draining = false;
      if (_queue.isEmpty) _setPlaying(false);
    }
  }

  void _setPlaying(bool value) {
    if (_isPlaying == value) return;
    _isPlaying = value;
    if (!_playing.isClosed) _playing.add(value);
  }

  @override
  Future<void> dispose() async {
    _generation++;
    _queue.clear();
    await _playing.close();
    final player = _player;
    _player = null;
    if (player != null) await player.dispose();
  }
}

/// Serves an in-memory clip to `just_audio` (which fetches audio through a
/// local proxy on native platforms and a data URL on the web).
class _BytesAudioSource extends StreamAudioSource {
  _BytesAudioSource(this.clip) : super(tag: 'bytes');
  final AudioClip clip;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final bytes = clip.bytes;
    final from = start ?? 0;
    final to = end ?? bytes.length;
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: to - from,
      offset: from,
      stream: Stream.value(bytes.sublist(from, to)),
      contentType: clip.mimeType,
    );
  }
}

final audioPlayerProvider = Provider<AudioPlayerService>((ref) {
  final player = JustAudioPlayerService();
  ref.onDispose(player.dispose);
  return player;
});
