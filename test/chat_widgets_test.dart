import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/theme.dart';
import 'package:nexusbot/features/attachments/attachment_widgets.dart';
import 'package:nexusbot/features/attachments/attachments_repository.dart';
import 'package:nexusbot/features/chat/chat_models.dart';
import 'package:nexusbot/features/chat/chat_sheets.dart';
import 'package:nexusbot/features/chat/chat_widgets.dart';
import 'package:nexusbot/features/chat/message_extras.dart';
import 'package:nexusbot/features/chat/tool_chips.dart';
import 'package:nexusbot/features/tools/tools_repository.dart';
import 'package:nexusbot/features/usage/usage_model.dart';
import 'package:nexusbot/features/usage/usage_widgets.dart';
import 'package:nexusbot/features/voice/recorder.dart';
import 'package:nexusbot/features/voice/voice_button.dart';
import 'package:nexusbot/shared/highlight_text.dart';

/// Layout smoke tests for the Phase 2 chat widgets: the approval card inside
/// the bubble, collapsible tool chips (with `call_id` hiding), the structured
/// citation strip and `<mark>` highlights. They exist mainly to catch
/// parent-data / layout mistakes the analyzer cannot see.
Widget host(Widget child) => ProviderScope(
      overrides: [attachmentContentLoaderProvider.overrideWithValue(FakeContentLoader())],
      child: MaterialApp(
        theme: buildNexusTheme(dark: true),
        home: Scaffold(body: ListView(children: [child])),
      ),
    );

/// Serves a 1×1 PNG for every content URL (the widgets never hit the network).
class FakeContentLoader implements AttachmentContentLoader {
  final loaded = <String>[];

  static final png = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
    0x52, //
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15,
    0xC4, //
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x64, 0x60, 0xF8,
    0x5F, //
    0x0F, 0x00, 0x02, 0x87, 0x01, 0x80, 0xEB, 0x47, 0xBA, 0x92, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, //
    0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ]);

  @override
  Future<AttachmentBytes> load(String url) async {
    loaded.add(url);
    return AttachmentBytes(bytes: png, mimeType: 'image/png');
  }
}

/// Scripted microphone for the push-to-talk tests.
class FakeRecorder implements Recorder {
  bool permission = true;
  bool recording = false;
  int starts = 0;
  int stops = 0;
  int cancels = 0;

  @override
  bool get isSupported => true;

  @override
  bool get isRecording => recording;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<void> start() async {
    starts++;
    recording = true;
  }

  @override
  Future<RecordedClip?> stop() async {
    stops++;
    recording = false;
    return RecordedClip(
      bytes: Uint8List.fromList([1, 2, 3]),
      mimeType: 'audio/wav',
      filename: 'voice.wav',
    );
  }

  @override
  Future<void> cancel() async {
    cancels++;
    recording = false;
  }

  @override
  Future<void> dispose() async {}
}

const imageAttachment = Attachment(
  id: 'att-img',
  kind: AttachmentKind.image,
  name: 'chart.png',
  mimeType: 'image/png',
  sizeBytes: 48213,
  width: 1200,
  height: 800,
  url: '/api/v1/sessions/s1/attachments/att-img/content',
);

const audioAttachment = Attachment(
  id: 'att-audio',
  kind: AttachmentKind.audio,
  name: 'clip.m4a',
  mimeType: 'audio/mp4',
  sizeBytes: 9000,
  url: '/api/v1/sessions/s1/attachments/att-audio/content',
  hasText: true,
);

const fileAttachment = Attachment(
  id: 'att-pdf',
  kind: AttachmentKind.file,
  name: 'notes.pdf',
  mimeType: 'application/pdf',
  sizeBytes: 12 * 1024,
  url: '/api/v1/sessions/s1/attachments/att-pdf/content',
  hasText: true,
);

const csvArtifact = Attachment(
  id: 'art-csv',
  kind: AttachmentKind.artifact,
  name: 'report.csv',
  mimeType: 'text/csv',
  sizeBytes: 2048,
  url: '/api/v1/sessions/s1/attachments/art-csv/content',
  hasText: true,
);

ChatMessage assistant({
  String content = '',
  ApprovalRequest? approval,
  List<ToolCall> toolCalls = const [],
  List<Citation> citations = const [],
  String? model,
  SiblingInfo? siblings,
  MessageFeedback? feedback,
  List<String> memoriesUsed = const [],
  List<Attachment> artifacts = const [],
  MessageAudio? audio,
}) =>
    ChatMessage(
      id: 'a1',
      sessionId: 's1',
      role: MessageRole.assistant,
      content: content,
      createdAt: DateTime(2026, 1, 1, 12),
      approval: approval,
      status: approval == null ? null : MessageStatus.awaitingApproval,
      toolCalls: toolCalls,
      citations: citations,
      model: model,
      siblings: siblings,
      feedback: feedback,
      memoriesUsed: memoriesUsed,
      artifacts: artifacts,
      audio: audio,
    );

ChatMessage user(
  String content, {
  SiblingInfo? siblings,
  List<Attachment> attachments = const [],
}) =>
    ChatMessage(
      id: 'u1',
      sessionId: 's1',
      role: MessageRole.user,
      content: content,
      createdAt: DateTime(2026, 1, 1, 12),
      siblings: siblings,
      attachments: attachments,
    );

const approval = ApprovalRequest(
  approvalId: 'ap1',
  sessionId: 's1',
  messageId: 'a1',
  toolCalls: [
    ApprovalToolCall(
      callId: 'c1',
      tool: 'web_search',
      input: {'query': 'flutter'},
      description: 'Searches the web',
    ),
  ],
);

void main() {
  testWidgets('approval card renders inside the bubble and reports the decision', (tester) async {
    ApprovalDecision? decision;
    await tester.pumpWidget(
      host(
        MessageBubble(
          message: assistant(approval: approval, model: 'gpt-4o-mini'),
          onRegenerate: null,
          isLastAssistant: true,
          onApprovalDecision: (d) => decision = d,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Approval required'), findsOneWidget);
    expect(find.text('web_search'), findsOneWidget);
    expect(find.text('Searches the web'), findsOneWidget);
    expect(
      find.textContaining('"query": "flutter"'),
      findsOneWidget,
      reason: 'pretty-printed input',
    );
    expect(find.text('· gpt-4o-mini'), findsOneWidget, reason: 'model caption in the actions row');

    await tester.tap(find.text('Deny'));
    expect(decision, ApprovalDecision.deny);
    await tester.tap(find.text('Approve'));
    expect(decision, ApprovalDecision.approve);
  });

  testWidgets('a stale approval shows a label instead of buttons', (tester) async {
    await tester.pumpWidget(
      host(
        MessageBubble(
          message: assistant(content: 'partial', approval: approval.copyWith(status: 'expired')),
          onRegenerate: null,
          isLastAssistant: false,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Approval expired'), findsOneWidget);
    expect(find.text('Approve'), findsNothing);
    expect(find.text('Deny'), findsNothing);
    expect(find.text('partial'), findsOneWidget, reason: 'text so far stays visible');
  });

  testWidgets('tool chips skip hidden call ids and expand to input / output', (tester) async {
    await tester.pumpWidget(
      host(
        MessageBubble(
          message: assistant(
            content: 'It is 4.',
            toolCalls: const [
              ToolCall(
                tool: 'calculator',
                callId: 'c1',
                input: {'expression': '2+2'},
                output: '4',
                latencyMs: 12,
              ),
              ToolCall(tool: 'web_search', callId: 'c2', output: 'r'),
            ],
          ),
          onRegenerate: null,
          isLastAssistant: false,
          hiddenToolCallIds: const {'c2'},
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Tool: calculator'), findsOneWidget);
    expect(find.text('Tool: web_search'), findsNothing, reason: 'rendered by a tool row instead');
    expect(find.text('12 ms'), findsOneWidget);
    expect(find.text('OUTPUT'), findsNothing);

    await tester.tap(find.text('Tool: calculator'));
    await tester.pump();
    expect(find.text('INPUT'), findsOneWidget);
    expect(find.textContaining('"expression": "2+2"'), findsOneWidget);
    expect(find.text('OUTPUT'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);

    await tester.tap(find.text('Tool: calculator'));
    await tester.pump();
    expect(find.text('OUTPUT'), findsNothing, reason: 'collapses again');
  });

  testWidgets('standalone tool chips render a denied run', (tester) async {
    await tester.pumpWidget(
      host(
        const ToolCallChips(
          calls: [ToolCall(tool: 'db_lookup', callId: 'c9', status: ToolCallStatus.denied)],
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Tool: db_lookup'));
    await tester.pump();
    expect(find.text('DENIED'), findsOneWidget);
    expect(find.text('This tool call was denied.'), findsOneWidget);
  });

  testWidgets('citation cards show the location and open on tap', (tester) async {
    Citation? opened;
    const citation = Citation(
      documentId: 'd1',
      documentName: 'spec.pdf',
      chunkId: 'ch1',
      chunkIndex: 3,
      page: 4,
      section: '2. Scope > 2.1 Goals',
      score: 0.83,
      excerpt: 'first chars',
    );
    await tester.pumpWidget(
      host(
        MessageBubble(
          message: assistant(content: 'Grounded.', citations: const [citation]),
          onRegenerate: null,
          isLastAssistant: false,
          onCitationTap: (c) => opened = c,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('spec.pdf'), findsOneWidget);
    expect(find.text('p. 4 · 2. Scope > 2.1 Goals'), findsOneWidget);
    expect(find.text('83%'), findsOneWidget);
    await tester.tap(find.text('spec.pdf'));
    expect(opened?.chunkId, 'ch1');
  });

  testWidgets('HighlightedText bolds the marked runs', (tester) async {
    await tester.pumpWidget(host(const HighlightedText('The <mark>invoice</mark> total')));
    await tester.pump();
    final text = tester.widget<Text>(find.byType(Text));
    final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(spans.map((s) => s.text), ['The ', 'invoice', ' total']);
    expect(spans[1].style?.fontWeight, FontWeight.w700);
    expect(spans[0].style, isNull);
    expect(find.text('The <mark>invoice</mark> total'), findsNothing, reason: 'tags are stripped');
  });

  // ── Phase 3 ──────────────────────────────────────────────────────────

  testWidgets('sibling switcher shows i/n and reports the direction', (tester) async {
    final deltas = <int>[];
    await tester.pumpWidget(
      host(
        MessageBubble(
          message: assistant(
            content: 'second try',
            siblings: const SiblingInfo(index: 1, count: 3),
          ),
          onRegenerate: null,
          isLastAssistant: false,
          onSwitchSibling: deltas.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SiblingSwitcher), findsOneWidget);
    expect(find.text('2/3'), findsOneWidget, reason: 'zero-based index shown one-based');

    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    expect(deltas, [-1, 1]);
  });

  testWidgets('a sibling switch in flight shows a spinner and disables the arrows', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      host(
        SiblingSwitcher(
          siblings: const SiblingInfo(index: 0, count: 2),
          onSwitch: (_) => taps++,
          busy: true,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('1/2'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    expect(taps, 0);
  });

  testWidgets('a user message with siblings renders the switcher on its actions row',
      (tester) async {
    await tester.pumpWidget(
      host(
        MessageBubble(
          message: user('edited twice', siblings: const SiblingInfo(index: 2, count: 3)),
          onRegenerate: null,
          isLastAssistant: false,
          onSwitchSibling: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsOneWidget);
  });

  testWidgets('feedback buttons report the rating and reflect the active one', (tester) async {
    final ratings = <int>[];
    await tester.pumpWidget(
      host(
        MessageBubble(
          message: assistant(content: 'An answer.'),
          onRegenerate: null,
          isLastAssistant: true,
          onFeedback: ratings.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FeedbackButtons), findsOneWidget);
    expect(find.byIcon(Icons.thumb_up_alt_outlined), findsOneWidget);
    expect(find.byIcon(Icons.thumb_down_alt_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.thumb_up_alt_outlined));
    await tester.tap(find.byIcon(Icons.thumb_down_alt_outlined));
    expect(ratings, [1, -1]);

    await tester.pumpWidget(
      host(
        MessageBubble(
          message: assistant(
            content: 'An answer.',
            feedback: const MessageFeedback(rating: -1, comment: 'meh'),
          ),
          onRegenerate: null,
          isLastAssistant: true,
          onFeedback: ratings.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.thumb_down_alt_rounded), findsOneWidget, reason: 'filled when active');
    expect(find.byIcon(Icons.thumb_up_alt_outlined), findsOneWidget);
  });

  testWidgets('feedback is hidden on a streaming or approval bubble', (tester) async {
    await tester.pumpWidget(
      host(
        MessageBubble(
          message: assistant(approval: approval),
          onRegenerate: null,
          isLastAssistant: true,
          onFeedback: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FeedbackButtons), findsNothing);
  });

  testWidgets('the memories caption counts the memories used and opens on tap', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      host(
        MessageBubble(
          message: assistant(content: 'Personalised.', memoriesUsed: const ['m1', 'm2', 'm3']),
          onRegenerate: null,
          isLastAssistant: false,
          onMemoriesTap: () => opened++,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Used 3 memories'), findsOneWidget);
    await tester.tap(find.text('Used 3 memories'));
    expect(opened, 1);
    expect(find.byType(MemoriesCaption), findsOneWidget);
  });

  testWidgets('the inline editor replaces the user text and submits the new content',
      (tester) async {
    String? submitted;
    var cancelled = 0;
    await tester.pumpWidget(
      host(
        MessageBubble(
          message: user('original question'),
          onRegenerate: null,
          isLastAssistant: false,
          editing: true,
          onSubmitEdit: (v) => submitted = v,
          onCancelEdit: () => cancelled++,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Save & send'), findsOneWidget);

    await tester.tap(find.text('Save & send'));
    expect(submitted, isNull, reason: 'unchanged text is a cancel');
    expect(cancelled, 1);

    await tester.enterText(find.byType(TextField), 'better question');
    await tester.tap(find.text('Save & send'));
    expect(submitted, 'better question');
  });

  testWidgets('the quota banner shows the figures, the reset time and a refresh button',
      (tester) async {
    var refreshed = 0;
    final quota = QuotaExceeded.fromDetails(
      const {
        'budget_usd_per_month': 10,
        'used_usd': 10.5,
        'resets_at': '2026-12-01T00:00:00Z',
      },
      message: 'spent',
    );
    await tester.pumpWidget(
      host(QuotaBanner(quota: quota, onRefresh: () => refreshed++)),
    );
    await tester.pump();
    expect(find.text('Monthly budget spent'), findsOneWidget);
    expect(find.textContaining(r'$10.50 of $10.00 spent'), findsOneWidget);
    expect(find.textContaining('Resets'), findsOneWidget);
    await tester.tap(find.text('Refresh'));
    expect(refreshed, 1);
  });

  testWidgets('the composer is disabled while the quota is exceeded', (tester) async {
    var sent = 0;
    await tester.pumpWidget(
      host(
        Composer(
          onSend: (_) => sent++,
          sending: false,
          enabled: false,
          disabledHint: 'Sending is paused',
          useRag: true,
          useTools: true,
          onToggleRag: (_) {},
          onToggleTools: (_) {},
          onStop: () {},
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Sending is paused'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    expect(sent, 0);
  });

  // ── Phase 4 ──────────────────────────────────────────────────────────

  testWidgets('pending attachment chips show the name, size and hint, and can be removed',
      (tester) async {
    var removed = 0;
    await tester.pumpWidget(
      host(
        Row(
          children: [
            PendingAttachmentChip(attachment: fileAttachment, onRemove: () => removed++),
            const PendingAttachmentChip(attachment: imageAttachment),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.text('notes.pdf'), findsOneWidget);
    expect(find.text('12 KB · Text extracted'), findsOneWidget);
    expect(find.byIcon(Icons.picture_as_pdf_outlined), findsOneWidget);
    expect(find.byType(AuthenticatedImage), findsOneWidget, reason: 'image thumbnail');
    expect(find.byIcon(Icons.close_rounded), findsOneWidget, reason: 'only the removable chip');
    await tester.tap(find.byIcon(Icons.close_rounded));
    expect(removed, 1);
  });

  testWidgets('a user bubble renders an image grid and file chips with the transcript hint',
      (tester) async {
    final opened = <Attachment>[];
    await tester.pumpWidget(
      host(
        MessageBubble(
          message: user('listen to this', attachments: const [imageAttachment, audioAttachment]),
          onRegenerate: null,
          isLastAssistant: false,
          onOpenAttachment: opened.add,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(MessageAttachments), findsOneWidget);
    expect(find.byType(AuthenticatedImage), findsOneWidget);
    expect(find.text('listen to this'), findsOneWidget);
    expect(find.text('clip.m4a'), findsOneWidget);
    expect(find.text('8.8 KB · Transcribed'), findsOneWidget);

    await tester.tap(find.text('clip.m4a'));
    expect(opened.map((a) => a.id), ['att-audio']);
    await tester.tap(find.byType(AuthenticatedImage));
    expect(opened.map((a) => a.id), ['att-audio', 'att-img']);
  });

  testWidgets('artifact cards list a reply\'s files with size, type and download', (tester) async {
    final opened = <Attachment>[];
    await tester.pumpWidget(
      host(
        MessageBubble(
          message: assistant(content: 'Here is the report.', artifacts: const [csvArtifact]),
          onRegenerate: null,
          isLastAssistant: false,
          onOpenArtifact: opened.add,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(ArtifactCard), findsOneWidget);
    expect(find.text('report.csv'), findsOneWidget);
    expect(find.text('2.0 KB · text/csv'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.download_rounded));
    expect(opened.single.id, 'art-csv');
  });

  testWidgets('an image artifact gets an inline preview', (tester) async {
    await tester.pumpWidget(
      host(
        ArtifactCard(
          artifact: const Attachment(
            id: 'art-img',
            kind: AttachmentKind.artifact,
            name: 'plot.png',
            mimeType: 'image/png',
            sizeBytes: 100,
            url: '/api/v1/sessions/s1/attachments/art-img/content',
          ),
          onOpen: () {},
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(AuthenticatedImage), findsOneWidget);
    expect(find.text('plot.png'), findsOneWidget);
  });

  testWidgets('a reply with a spoken version offers Play reply / Stop', (tester) async {
    var taps = 0;
    const audio = MessageAudio(attachmentId: 'spk', url: '/api/v1/x', format: 'mp3', chunks: 2);
    await tester.pumpWidget(
      host(
        MessageBubble(
          message: assistant(content: 'Spoken.', audio: audio),
          onRegenerate: null,
          isLastAssistant: false,
          onPlayAudio: () => taps++,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Play reply'), findsOneWidget);
    await tester.tap(find.text('Play reply'));
    expect(taps, 1);

    await tester.pumpWidget(
      host(
        MessageBubble(
          message: assistant(content: 'Spoken.', audio: audio),
          onRegenerate: null,
          isLastAssistant: false,
          onPlayAudio: () => taps++,
          playingAudio: true,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Play reply'), findsNothing);
  });

  testWidgets('the composer shows pending uploads and gates photos on vision', (tester) async {
    final picked = <AttachmentSource>[];
    final removed = <Attachment>[];
    await tester.pumpWidget(
      host(
        Composer(
          onSend: (_) {},
          sending: false,
          useRag: true,
          useTools: true,
          onToggleRag: (_) {},
          onToggleTools: (_) {},
          onStop: () {},
          attachments: const [fileAttachment],
          uploading: 1,
          onAttach: picked.add,
          onRemoveAttachment: removed.add,
          canAttachImages: false,
          imageAttachHint: 'Llama 3 cannot read images — pick a vision model',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('notes.pdf'), findsOneWidget);
    expect(find.text('Uploading…'), findsOneWidget);
    expect(find.text('Add a message about your attachment…'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    expect(removed.single.id, 'att-pdf');

    await tester.tap(find.byIcon(Icons.attach_file_rounded));
    // The "Uploading…" spinner never settles; pump the menu animation instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Photo library'), findsOneWidget);
    expect(find.text('Llama 3 cannot read images — pick a vision model'), findsWidgets);
    final gallery = tester.widget<PopupMenuItem<AttachmentSource>>(
      find.widgetWithText(PopupMenuItem<AttachmentSource>, 'Photo library'),
    );
    expect(gallery.enabled, isFalse);
    await tester.tap(find.text('File'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(picked, [AttachmentSource.file]);
  });

  testWidgets('the composer renders the voice button and the Speak chip', (tester) async {
    bool? speak;
    await tester.pumpWidget(
      host(
        Composer(
          onSend: (_) {},
          sending: false,
          useRag: true,
          useTools: true,
          onToggleRag: (_) {},
          onToggleTools: (_) {},
          onStop: () {},
          voiceButton: const VoiceButton(state: VoiceButtonState.idle, onTap: null),
          speakReplies: false,
          onToggleSpeak: (v) => speak = v,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(VoiceButton), findsOneWidget);
    expect(find.text('Speak'), findsOneWidget);
    await tester.tap(find.text('Speak'));
    expect(speak, isTrue);
  });

  testWidgets('the voice button reflects each state', (tester) async {
    var taps = 0;
    Future<void> pumpState(VoiceButtonState state) async {
      await tester.pumpWidget(host(VoiceButton(state: state, onTap: () => taps++)));
      await tester.pump();
    }

    await pumpState(VoiceButtonState.idle);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    await tester.tap(find.byType(VoiceButton));
    expect(taps, 1);

    await pumpState(VoiceButtonState.recording);
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    await tester.tap(find.byType(VoiceButton));
    expect(taps, 2);

    await pumpState(VoiceButtonState.processing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byType(VoiceButton));
    expect(taps, 2, reason: 'no taps while transcribing');

    await pumpState(VoiceButtonState.disabled);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    await tester.tap(find.byType(VoiceButton));
    expect(taps, 2);
  });

  testWidgets('push-to-talk toggles the recorder and hands over the clip', (tester) async {
    final recorder = FakeRecorder();
    final clips = <RecordedClip>[];
    final errors = <String>[];
    await tester.pumpWidget(
      host(PushToTalkButton(recorder: recorder, onClip: clips.add, onError: errors.add)),
    );
    await tester.pump();
    await tester.tap(find.byType(VoiceButton));
    await tester.pump();
    expect(recorder.starts, 1);
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget, reason: 'recording state');

    await tester.tap(find.byType(VoiceButton));
    await tester.pump();
    expect(recorder.stops, 1);
    expect(clips.single.filename, 'voice.wav');
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    expect(errors, isEmpty);
  });

  testWidgets('push-to-talk reports a denied microphone', (tester) async {
    final recorder = FakeRecorder()..permission = false;
    final errors = <String>[];
    await tester.pumpWidget(
      host(PushToTalkButton(recorder: recorder, onClip: (_) {}, onError: errors.add)),
    );
    await tester.pump();
    await tester.tap(find.byType(VoiceButton));
    await tester.pump();
    expect(recorder.starts, 0);
    expect(errors, ['Microphone access was denied']);
  });

  test('tools are grouped by source: built-ins first, then each MCP server', () {
    const tools = [
      ToolInfo(name: 'mcp:zulip:send', source: 'mcp:zulip'),
      ToolInfo(name: 'calculator'),
      ToolInfo(name: 'mcp:github:search_issues', source: 'mcp:github', requiresApproval: true),
      ToolInfo(name: 'web_search', source: 'builtin', requiresApproval: true),
      ToolInfo(name: 'mcp:github:create_issue', source: 'mcp:github'),
    ];
    final groups = groupToolsBySource(tools);
    expect(groups.map((g) => g.label), ['Built-in', 'github', 'zulip']);
    expect(groups.first.isBuiltin, isTrue);
    expect(groups.first.tools.map((t) => t.name), ['calculator', 'web_search']);
    expect(groups[1].tools.map((t) => t.shortName), ['search_issues', 'create_issue']);
    expect(tools.first.serverName, 'zulip');
    expect(tools.first.sourceLabel, 'zulip');
    expect(tools[1].isBuiltin, isTrue);
    expect(tools[1].shortName, 'calculator');
    expect(groupToolsBySource(const []), isEmpty);
  });

  testWidgets('the tool picker shows one section per source', (tester) async {
    const tools = [
      ToolInfo(name: 'calculator', description: 'Math'),
      ToolInfo(name: 'mcp:github:search_issues', description: 'Find issues', source: 'mcp:github'),
    ];
    ToolSelection? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildNexusTheme(dark: true),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showToolPickerSheet(
                  context,
                  tools: tools,
                  selected: const ['calculator'],
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('BUILT-IN'), findsOneWidget);
    expect(find.text('GITHUB'), findsOneWidget);
    expect(find.text('MCP server'), findsOneWidget);
    expect(find.text('search_issues'), findsOneWidget, reason: 'server prefix stripped');
    expect(find.text('calculator'), findsOneWidget);

    await tester.tap(find.text('search_issues'));
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(result?.names, ['calculator', 'mcp:github:search_issues'], reason: 'full names go out');
  });
}
