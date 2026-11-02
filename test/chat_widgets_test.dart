import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/theme.dart';
import 'package:nexusbot/features/chat/chat_models.dart';
import 'package:nexusbot/features/chat/chat_widgets.dart';
import 'package:nexusbot/features/chat/message_extras.dart';
import 'package:nexusbot/features/chat/tool_chips.dart';
import 'package:nexusbot/features/usage/usage_model.dart';
import 'package:nexusbot/features/usage/usage_widgets.dart';
import 'package:nexusbot/shared/highlight_text.dart';

/// Layout smoke tests for the Phase 2 chat widgets: the approval card inside
/// the bubble, collapsible tool chips (with `call_id` hiding), the structured
/// citation strip and `<mark>` highlights. They exist mainly to catch
/// parent-data / layout mistakes the analyzer cannot see.
Widget host(Widget child) => MaterialApp(
      theme: buildNexusTheme(dark: true),
      home: Scaffold(body: ListView(children: [child])),
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
    );

ChatMessage user(String content, {SiblingInfo? siblings}) => ChatMessage(
      id: 'u1',
      sessionId: 's1',
      role: MessageRole.user,
      content: content,
      createdAt: DateTime(2026, 1, 1, 12),
      siblings: siblings,
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
}
