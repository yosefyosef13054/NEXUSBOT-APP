import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api_exception.dart';
import '../core/breakpoints.dart';
import '../core/preferences.dart';
import '../core/router.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../features/chat/chat_models.dart';
import '../features/chat/chat_repository.dart';
import 'sidebar.dart';

/// App shell rendered by the router's [ShellRoute]: it stays mounted while
/// the child route (`/`, `/chat/:id`, `/documents`, `/settings`) changes.
/// Adaptive: drawer on mobile, persistent sidebar on wide layouts.
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

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    if (context.isWide) {
      return Scaffold(
        backgroundColor: t.background,
        body: Row(
          children: [
            Sidebar(
              selectedSessionId: widget.selectedSessionId,
              location: widget.location,
              width: context.isDesktop ? 280 : 260,
            ),
            Expanded(child: widget.child),
          ],
        ),
      );
    }

    return Scaffold(
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
      body: widget.child,
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
      final repo = await ref.read(chatRepositoryProvider.future);
      final s = await repo.createSession(model: ref.read(prefsProvider).model);
      ref.invalidate(sessionListProvider);
      if (!mounted) return;
      _redirected = true;
      context.go(AppRoutes.chat(s.id));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
              title: 'Welcome to NexusBot',
              subtitle:
                  'Start a conversation, upload documents to chat with them, or enable tools to let the AI take actions.',
              action: NexusButton(
                label: 'Start new chat',
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
      icon: const Icon(Icons.menu_rounded),
      onPressed: () => context.findAncestorStateOfType<HomeShellState>()?.openDrawer(),
    );
  }
}
