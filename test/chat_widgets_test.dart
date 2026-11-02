import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/theme.dart';
import 'package:nexusbot/features/chat/chat_models.dart';
import 'package:nexusbot/features/chat/chat_widgets.dart';
import 'package:nexusbot/features/chat/tool_chips.dart';
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
    expect(find.textContaining('"query": "flutter"'), findsOneWidget, reason: 'pretty-printed input');
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
}
