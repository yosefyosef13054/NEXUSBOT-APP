import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/breakpoints.dart';
import '../core/connectivity.dart';
import '../core/router.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../features/chat/chat_models.dart';
import '../features/chat/chat_repository.dart';
import '../features/chat/new_chat.dart';
import '../features/chat/send_queue.dart';
import '../l10n/l10n.dart';
import 'offline_banner.dart';
import 'sidebar.dart';

/// App shell rendered by the router's [ShellRoute]: it stays mounted while
/// the child route (`/`, `/chat/:id`, `/documents`, `/settings`) changes.
/// Adaptive: drawer on mobile, persistent sidebar on wide layouts.
///
/// Also hosts the offline banner and the app-wide keyboard shortcuts
/// (Ctrl / Cmd + N new chat, Ctrl / Cmd + K search).
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({
    super.key,
    required this.child,
    required this.location,
    this.selectedSessionId,
  });

  /// The active child route's widget (the shell's inner navigator).
  final Widget child;

  /// Current path, used to highlight the active sidebar entry.
  final String location;

  /// Session id from `/chat/:sessionId`, if that route is active.
  final String? selectedSessionId;

  @override
  ConsumerState<HomeShell> createState() => HomeShellState();
}

class HomeShellState extends ConsumerState<HomeShell> with WidgetsBindingObserver {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Titles are generated in the background; pick them up on resume.
    if (state == AppLifecycleState.resumed) ref.invalidate(sessionListProvider);
  }

  /// Opens the shell's navigation drawer (mobile layout). Called from the
  /// hamburger button, which lives inside an inner screen's Scaffold and so
  /// can't reach this drawer via `Scaffold.of`.
  void openDrawer() => _scaffoldKey.currentState?.openDrawer();

  void closeDrawer() {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold != null && scaffold.isDrawerOpen) scaffold.closeDrawer();
  }

  /// Ctrl / Cmd + K: focus the sidebar's search field (opening the drawer
  /// first on mobile).
  void focusSearch() {
    final node = ref.read(sidebarSearchFocusProvider);
    if (context.isWide) {
      node.requestFocus();
      return;
    }
    openDrawer();
    WidgetsBinding.instance.addPostFrameCallback((_) => node.requestFocus());
  }

  Future<void> _newChat() async {
    await startNewChat(context, ref);
    if (mounted) closeDrawer();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final online = ref.watch(onlineProvider);
    final queue = ref.watch(sendQueueProvider);

    final body = Column(
      children: [
        if (!online) OfflineBanner(queued: queue.pendingCount, failed: queue.failedCount),
        Expanded(child: widget.child),
      ],
    );

    final Widget scaffold;
    if (context.isWide) {
      scaffold = Scaffold(
        backgroundColor: t.background,
        body: Row(
          children: [
            Sidebar(
              selectedSessionId: widget.selectedSessionId,
              location: widget.location,
              width: context.isDesktop ? 280 : 260,
            ),
            Expanded(child: body),
          ],
        ),
      );
    } else {
      scaffold = Scaffold(
        key: _scaffoldKey,
        backgroundColor: t.background,
        drawer: Drawer(
          backgroundColor: t.surface,
          width: 300,
          child: Sidebar(
            selectedSessionId: widget.selectedSessionId,
            location: widget.location,
            width: 300,
            showClose: closeDrawer,
            onNavigated: closeDrawer,
          ),
        ),
        body: body,
      );
    }

    return AppShortcuts(onNewChat: _newChat, onFocusSearch: focusSearch, child: scaffold);
  }
}

/// Desktop keyboard shortcuts of the shell. [Focus] with autofocus keeps a
/// focus node in the subtree so the bindings fire even when no field is
/// focused; a focused text field passes unhandled keys up to them.
class AppShortcuts extends StatelessWidget {
  const AppShortcuts({
    super.key,
    required this.onNewChat,
    required this.onFocusSearch,
    required this.child,
  });

  final VoidCallback onNewChat;
  final VoidCallback onFocusSearch;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): onNewChat,
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): onNewChat,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): onFocusSearch,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): onFocusSearch,
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}

/// The `/` route: opens the most recent chat as soon as the session list is
/// known, or offers a "New chat" call to action when there is none.
class HomeLanding extends ConsumerStatefulWidget {
  const HomeLanding({super.key});

  @override
  ConsumerState<HomeLanding> createState() => _HomeLandingState();
}

class _HomeLandingState extends ConsumerState<HomeLanding> {
  bool _creating = false;
  bool _redirected = false;

  @override
  void initState() {
    super.initState();
    // The list may already be loaded (e.g. navigating back to `/`).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeOpenMostRecent(ref.read(sessionListProvider));
    });
  }

  void _maybeOpenMostRecent(AsyncValue<List<ChatSession>> sessions) {
    if (_redirected || !mounted) return;
    final list = sessions.valueOrNull;
    if (list == null || list.isEmpty) return;
    _redirected = true;
    context.go(AppRoutes.chat(list.first.id));
  }

  Future<void> _create() async {
    setState(() => _creating = true);
    try {
      final id = await startNewChat(context, ref);
      if (id != null) _redirected = true;
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    ref.listen(sessionListProvider, (_, next) => _maybeOpenMostRecent(next));
    final sessions = ref.watch(sessionListProvider);
    final resolving = sessions.isLoading && !sessions.hasValue;

    return Scaffold(
      backgroundColor: t.background,
      appBar: context.isMobile
          ? AppBar(
              leading: const MenuButton(),
              title: const NexusWordmark(fontSize: 18),
            )
          : null,
      body: resolving
          ? const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(NexusColors.crimson),
                ),
              ),
            )
          : EmptyState(
              icon: Icons.auto_awesome_rounded,
              title: l10n.homeWelcomeTitle,
              subtitle: l10n.homeWelcomeSubtitle,
              action: NexusButton(
                label: l10n.homeStartNewChat,
                icon: Icons.add_rounded,
                loading: _creating,
                expand: false,
                onPressed: _creating ? null : _create,
              ),
            ),
    );
  }
}

/// Hamburger button that opens the shell drawer on mobile.
class MenuButton extends StatelessWidget {
  const MenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: context.l10n.menuOpen,
      icon: const Icon(Icons.menu_rounded),
      onPressed: () => context.findAncestorStateOfType<HomeShellState>()?.openDrawer(),
    );
  }
}
