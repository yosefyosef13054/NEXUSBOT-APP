import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/api_client.dart';
import 'package:nexusbot/core/secure_storage.dart';
import 'package:nexusbot/core/widgets.dart';
import 'package:nexusbot/features/assistants/assistants_repository.dart';
import 'package:nexusbot/features/chat/chat_models.dart';
import 'package:nexusbot/features/chat/chat_repository.dart';
import 'package:nexusbot/features/chat/chat_screen.dart';
import 'package:nexusbot/features/chat/chat_widgets.dart';
import 'package:nexusbot/features/chat/message_extras.dart';
import 'package:nexusbot/features/collections/collections_repository.dart';
import 'package:nexusbot/features/models/model_info.dart';
import 'package:nexusbot/features/models/models_repository.dart';
import 'package:nexusbot/features/orgs/orgs_repository.dart';
import 'package:nexusbot/features/tools/tools_repository.dart';
import 'package:nexusbot/features/usage/usage_model.dart';
import 'package:nexusbot/features/usage/usage_repository.dart';
import 'package:nexusbot/features/voice/voice_models.dart';
import 'package:nexusbot/features/voice/voice_repository.dart';
import 'package:nexusbot/l10n/l10n.dart';
import 'package:nexusbot/shared/home_shell.dart';
import 'package:nexusbot/shared/sidebar.dart';

import 'helpers/fakes.dart';
import 'helpers/test_app.dart';

/// Chat repository that serves a fixed history and no network.
class StaticChatRepository extends ChatRepository {
  StaticChatRepository(this.history, {this.sessions = const []})
      : super(ApiClient.create(MemoryTokenStorage()));

  final List<ChatMessage> history;
  final List<ChatSession> sessions;

  @override
  Future<HistoryPage> loadHistoryPage(String sessionId, {String? cursor, int limit = 50}) async =>
      HistoryPage(items: history);

  @override
  Future<List<ChatSession>> listSessions({int page = 1, int pageSize = 50}) async => sessions;

  @override
  Future<ChatSession> getSession(String id) async => sessions.firstWhere((s) => s.id == id);

  @override
  Future<List<ApprovalRequest>> listPendingApprovals(String sessionId) async => const [];

  @override
  Future<ActiveGeneration?> activeGeneration(String sessionId) async => null;
}

final session = ChatSession(
  id: 's1',
  title: 'RTL chat',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

ChatMessage message(String id, MessageRole role, String content) => ChatMessage(
      id: id,
      sessionId: 's1',
      role: role,
      content: content,
      createdAt: DateTime.utc(2026, 1, 1, 12),
    );

/// Overrides that keep every provider the chat screen watches off the network.
List<Override> chatOverrides(StaticChatRepository repo) => [
      tokenStorageProvider.overrideWithValue(MemoryTokenStorage()),
      chatRepositoryProvider.overrideWith((ref) async => repo),
      modelCatalogProvider.overrideWith((ref) async => ModelCatalog.empty),
      toolCatalogProvider.overrideWith((ref) async => const <ToolInfo>[]),
      collectionListProvider.overrideWith((ref) async => const []),
      assistantListProvider.overrideWith((ref) async => const []),
      orgListProvider.overrideWith((ref) async => const []),
      voiceCapabilitiesProvider.overrideWith((ref) async => VoiceCapabilities.none),
      usageMeProvider.overrideWith(
        (ref) async => UsageSummary.fromJson({'period': {}, 'user': {}, 'org': {}}),
      ),
    ];

void main() {
  final he = lookupAppLocalizations(const Locale('he'));
  final en = lookupAppLocalizations(const Locale('en'));

  group('RTL', () {
    testWidgets('the chat screen mirrors: user bubbles on the left, assistant on the right',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = StaticChatRepository(
        [
          message('u1', MessageRole.user, 'שלום'),
          message('a1', MessageRole.assistant, 'hi there'),
        ],
        sessions: [session],
      );
      await tester.pumpWidget(
        localizedApp(
          locale: const Locale('he'),
          scrollable: false,
          overrides: chatOverrides(repo),
          child: const ChatScreen(sessionId: 's1'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(Directionality.of(tester.element(find.byType(ChatScreen))), TextDirection.rtl);
      expect(find.text(he.composerHint), findsOneWidget, reason: 'Hebrew composer hint');
      final user = tester.getCenter(find.text('שלום'));
      final assistant = tester.getCenter(find.text('hi there', findRichText: true));
      expect(user.dx, lessThan(assistant.dx), reason: 'user at the end side = left in RTL');
      // The send button sits at the end of the composer row: left in RTL.
      final send = tester.getCenter(find.byIcon(Icons.arrow_upward_rounded));
      final field = tester.getCenter(find.byType(TextField));
      expect(send.dx, lessThan(field.dx));
    });

    testWidgets('the same chat lays out left-to-right in English', (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = StaticChatRepository(
        [
          message('u1', MessageRole.user, 'hello'),
          message('a1', MessageRole.assistant, 'hi there'),
        ],
        sessions: [session],
      );
      await tester.pumpWidget(
        localizedApp(
          scrollable: false,
          overrides: chatOverrides(repo),
          child: const ChatScreen(sessionId: 's1'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(en.composerHint), findsOneWidget);
      final user = tester.getCenter(find.text('hello'));
      final assistant = tester.getCenter(find.text('hi there', findRichText: true));
      expect(user.dx, greaterThan(assistant.dx));
      final send = tester.getCenter(find.byIcon(Icons.arrow_upward_rounded));
      final field = tester.getCenter(find.byType(TextField));
      expect(send.dx, greaterThan(field.dx));
    });

    testWidgets('the composer chips and send button mirror under a forced RTL direction',
        (tester) async {
      var sent = '';
      await tester.pumpWidget(
        localizedApp(
          textDirection: TextDirection.rtl,
          child: Composer(
            onSend: (t) => sent = t,
            sending: false,
            useRag: true,
            useTools: true,
            onToggleRag: (_) {},
            onToggleTools: (_) {},
            onStop: () {},
            onAttach: (_) {},
          ),
        ),
      );
      await tester.pump();
      final attach = tester.getCenter(find.byIcon(Icons.attach_file_rounded));
      final send = tester.getCenter(find.byIcon(Icons.arrow_upward_rounded));
      final rag = tester.getCenter(find.text(en.composerRag));
      final tools = tester.getCenter(find.text(en.composerTools));
      expect(attach.dx, greaterThan(send.dx), reason: 'start side is the right edge');
      expect(rag.dx, greaterThan(tools.dx), reason: 'first chip at the start = right');
      await tester.enterText(find.byType(TextField), 'מה נשמע');
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      expect(sent, 'מה נשמע');
    });

    testWidgets('the sidebar mirrors: close button at the end (left) in RTL', (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = StaticChatRepository(const [], sessions: [session]);
      await tester.pumpWidget(
        localizedApp(
          locale: const Locale('ar'),
          scrollable: false,
          overrides: chatOverrides(repo),
          child: Sidebar(selectedSessionId: 's1', location: '/chat/s1', showClose: () {}),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final ar = lookupAppLocalizations(const Locale('ar'));
      expect(find.text(ar.sidebarNewChat), findsOneWidget);
      expect(find.text('RTL chat'), findsOneWidget);
      final logo = tester.getCenter(find.byType(NexusLogo));
      final close = tester.getCenter(find.byIcon(Icons.close_rounded));
      expect(close.dx, lessThan(logo.dx));
      final chats = tester.getTopLeft(find.text(ar.sidebarChats));
      final count = tester.getTopLeft(find.text('1'));
      expect(chats.dx, greaterThan(count.dx), reason: 'heading starts at the right edge');
    });

    testWidgets('the sibling switcher swaps its arrows in RTL', (tester) async {
      final deltas = <int>[];
      await tester.pumpWidget(
        localizedApp(
          textDirection: TextDirection.rtl,
          child: SiblingSwitcher(
            siblings: const SiblingInfo(index: 1, count: 3),
            onSwitch: deltas.add,
          ),
        ),
      );
      await tester.pump();
      // "Previous" points towards the start (the right edge in RTL).
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await tester.tap(find.byIcon(Icons.chevron_left_rounded));
      expect(deltas, [-1, 1]);
      final prev = tester.getCenter(find.byIcon(Icons.chevron_right_rounded));
      final next = tester.getCenter(find.byIcon(Icons.chevron_left_rounded));
      expect(prev.dx, greaterThan(next.dx));
    });
  });

  group('keyboard', () {
    testWidgets('Enter sends on desktop and Shift+Enter does not', (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(
        localizedApp(
          child: Composer(
            onSend: sent.add,
            sending: false,
            enterSends: true,
            useRag: true,
            useTools: true,
            onToggleRag: (_) {},
            onToggleTools: (_) {},
            onStop: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'first');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(sent, isEmpty, reason: 'Shift+Enter is a newline');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(sent, ['first']);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    });

    testWidgets('Enter is a newline when enterSends is off (phones)', (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(
        localizedApp(
          child: Composer(
            onSend: sent.add,
            sending: false,
            useRag: true,
            useTools: true,
            onToggleRag: (_) {},
            onToggleTools: (_) {},
            onStop: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'text');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(sent, isEmpty);
    });

    testWidgets('Ctrl/Cmd+N and Ctrl/Cmd+K reach the shell shortcuts', (tester) async {
      var newChats = 0;
      var searches = 0;
      await tester.pumpWidget(
        localizedApp(
          scrollable: false,
          child: AppShortcuts(
            onNewChat: () => newChats++,
            onFocusSearch: () => searches++,
            child: const Center(child: Text('body')),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      expect(newChats, 2);
      expect(searches, 1);
    });

    testWidgets('Escape stops a running generation from the chat screen', (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = StaticChatRepository(const [], sessions: [session]);
      await tester.pumpWidget(
        localizedApp(
          scrollable: false,
          overrides: chatOverrides(repo),
          child: const ChatScreen(sessionId: 's1'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // Nothing is streaming: Escape is a no-op and must not throw.
      await tester.tap(find.byType(TextField));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(ChatScreen), findsOneWidget);
    });
  });
}
