import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import 'recorder.dart';

/// What the microphone button shows.
enum VoiceButtonState {
  /// Tap (or hold) to start recording.
  idle,

  /// Capturing audio; tap (or release) to send.
  recording,

  /// The clip was sent and the transcript / reply is on its way.
  processing,

  /// Recording is not possible right now (a turn is in flight, the budget is
  /// spent, no microphone permission, …).
  disabled,
}

/// The composer's push-to-talk button: a microphone that pulses red while
/// recording and spins while the clip is being transcribed. Stateless — the
/// state is owned by [PushToTalkButton] (or a test).
class VoiceButton extends StatelessWidget {
  const VoiceButton({
    super.key,
    required this.state,
    required this.onTap,
    this.onHoldStart,
    this.onHoldEnd,
    this.tooltip,
  });

  final VoiceButtonState state;
  final VoidCallback? onTap;

  /// Hold-to-talk: start on press, finish on release.
  final VoidCallback? onHoldStart;
  final VoidCallback? onHoldEnd;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final enabled = state != VoiceButtonState.disabled && state != VoiceButtonState.processing;
    final recording = state == VoiceButtonState.recording;
    final color = switch (state) {
      VoiceButtonState.recording => Colors.white,
      VoiceButtonState.idle => t.textSecondary,
      VoiceButtonState.processing || VoiceButtonState.disabled => t.textMuted,
    };
    final label = tooltip ??
        switch (state) {
          VoiceButtonState.idle => l10n.voiceHoldOrTap,
          VoiceButtonState.recording => l10n.voiceRecording,
          VoiceButtonState.processing => l10n.voiceTranscribing,
          VoiceButtonState.disabled => l10n.voiceUnavailable,
        };
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          onLongPressStart: enabled && onHoldStart != null ? (_) => onHoldStart!() : null,
          onLongPressEnd: enabled && onHoldEnd != null ? (_) => onHoldEnd!() : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            margin: const EdgeInsets.symmetric(vertical: 6),
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              gradient: recording ? NexusColors.redGradient : null,
              color: recording ? null : t.surfaceHigher,
              borderRadius: const BorderRadius.all(NexusRadius.md),
              boxShadow: recording
                  ? const [
                      BoxShadow(
                        color: NexusColors.crimsonGlow,
                        blurRadius: 16,
                        spreadRadius: -2,
                        offset: Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: state == VoiceButtonState.processing
                ? Center(
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(t.textMuted),
                      ),
                    ),
                  )
                : Icon(
                    recording ? Icons.stop_rounded : Icons.mic_rounded,
                    size: 18,
                    color: color,
                  ),
          ),
        ),
      ),
    );
  }
}

/// Owns the recording lifecycle around a [Recorder]: tap toggles, hold talks.
/// A finished clip goes to [onClip]; permission and microphone problems go
/// to [onError] (already translated).
class PushToTalkButton extends StatefulWidget {
  const PushToTalkButton({
    super.key,
    required this.recorder,
    required this.onClip,
    this.onError,
    this.enabled = true,
    this.processing = false,
    this.maxDuration = const Duration(minutes: 2),
  });

  final Recorder recorder;
  final ValueChanged<RecordedClip> onClip;
  final ValueChanged<String>? onError;
  final bool enabled;

  /// The last clip is being transcribed (the turn is in flight).
  final bool processing;

  /// Recording stops by itself after this long.
  final Duration maxDuration;

  @override
  State<PushToTalkButton> createState() => _PushToTalkButtonState();
}

class _PushToTalkButtonState extends State<PushToTalkButton> {
  bool _recording = false;
  bool _busy = false;
  Timer? _limit;

  @override
  void dispose() {
    _limit?.cancel();
    if (_recording) unawaited(widget.recorder.cancel());
    super.dispose();
  }

  Future<void> _start() async {
    if (_recording || _busy || !widget.enabled) return;
    final l10n = context.l10n;
    _busy = true;
    try {
      if (!await widget.recorder.hasPermission()) {
        widget.onError?.call(l10n.voiceMicDenied);
        return;
      }
      await widget.recorder.start();
      if (!mounted) {
        await widget.recorder.cancel();
        return;
      }
      setState(() => _recording = true);
      _limit = Timer(widget.maxDuration, _finish);
    } catch (e) {
      widget.onError?.call(l10n.voiceStartFailed('$e'));
    } finally {
      _busy = false;
    }
  }

  Future<void> _finish() async {
    _limit?.cancel();
    _limit = null;
    if (!_recording || _busy) return;
    final l10n = context.l10n;
    _busy = true;
    try {
      final clip = await widget.recorder.stop();
      if (mounted) setState(() => _recording = false);
      if (clip == null || clip.isEmpty) {
        widget.onError?.call(l10n.voiceNothingRecorded);
        return;
      }
      widget.onClip(clip);
    } catch (e) {
      if (mounted) setState(() => _recording = false);
      widget.onError?.call(l10n.voiceRecordingFailed('$e'));
    } finally {
      _busy = false;
    }
  }

  void _toggle() {
    if (_recording) {
      unawaited(_finish());
    } else {
      unawaited(_start());
    }
  }

  @override
  Widget build(BuildContext context) {
    final VoiceButtonState state;
    if (_recording) {
      state = VoiceButtonState.recording;
    } else if (widget.processing) {
      state = VoiceButtonState.processing;
    } else if (!widget.enabled || !widget.recorder.isSupported) {
      state = VoiceButtonState.disabled;
    } else {
      state = VoiceButtonState.idle;
    }
    return VoiceButton(
      state: state,
      onTap: _toggle,
      onHoldStart: _recording ? null : () => unawaited(_start()),
      onHoldEnd: () => unawaited(_finish()),
    );
  }
}
