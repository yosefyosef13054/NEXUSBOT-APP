import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/router.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../features/auth/auth_providers.dart';
import '../features/auth/auth_repository.dart';
import '../features/chat/chat_models.dart';
import '../features/chat/chat_repository.dart';
import '../features/chat/new_chat.dart';
import '../features/orgs/org_switcher.dart';
import '../features/usage/usage_repository.dart';
import '../features/usage/usage_widgets.dart';
import '../l10n/l10n.dart';
import 'highlight_text.dart';

/// Focus node of the sidebar's search field, so the Ctrl / Cmd + K shortcut
/// (handled by the shell) can reach it.
final sidebarSearchFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode(debugLabel: 'sidebar-search');
  ref.onDispose(node.dispose);
  return node;
});

/// Persistent left sidebar shown on tablet/desktop (and inside the drawer on
/// mobile). Contains:
/// - Brand + the workspace switcher (active organization)
/// - "New chat" button (opens the assistant picker when the workspace has
///   assistants)
/// - Search field: filters chat titles locally and, debounced, runs
///   `POST /search` across message contents (results show the server's
///   `<mark>` highlights)
/// - Session list (with rename/delete actions)
/// - Documents / Collections / Assistants / Memory / Settings links
/// - Usage meter for the month
/// - User profile dropdown (settings + sign out)
///
/// Navigation goes through the router (`context.go`), so the selected session
/// and active section are derived from the current location. Every layout
/// uses logical (start / end) geometry, so it mirrors under RTL.
class Sidebar extends ConsumerStatefulWidget {
  const Sidebar({
    super.key,
    required this.selectedSessionId,
    required this.location,
    this.width = 280,
    this.showClose,
    this.onNavigated,
  });

  final String? selectedSessionId;

  /// Current route path (highlights Documents / Settings).
  final String location;
  final double width;

  /// If set, shown as a close button in the header (used when the sidebar
  /// is rendered inside a drawer).
  final VoidCallback? showClose;

  /// Called after any navigation (closes the drawer on mobile).
  final VoidCallback? onNavigated;

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
  /// Wait for typing to pause before hitting `POST /search`.
  static const searchDebounce = Duration(milliseconds: 350);

  final _search = TextEditingController();
  bool _creating = false;

  Timer? _debounce;
  List<SearchResult>? _results;
  bool _searching = false;
  String? _searchError;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    setState(() {});
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < 2) {
      setState(() {
        _results = null;
        _searching = false;
        _searchError = null;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(searchDebounce, () => _runSearch(query));
  }

  Future<void> _runSearch(String query) async {
    try {
      final repo = await ref.read(chatRepositoryProvider.future);
      final results = await repo.search(query);
      if (!mounted || _search.text.trim() != query) return; // stale
      setState(() {
        _results = results;
        _searching = false;
        _searchError = null;
      });
    } catch (e) {
      if (!mounted || _search.text.trim() != query) return;
      setState(() {
        _results = null;
        _searching = false;
        _searchError = context.describeError(e);
      });
    }
  }

  void _clearSearch() {
    _debounce?.cancel();
    setState(() {
      _search.clear();
      _results = null;
      _searching = false;
      _searchError = null;
    });
  }

  void _go(String location) {
    context.go(location);
    widget.onNavigated?.call();
  }

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.describeError(e))));
  }

  Future<void> _newChat() async {
    setState(() => _creating = true);
    try {
      final id = await startNewChat(context, ref);
      if (id != null) widget.onNavigated?.call();
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _rename(ChatSession s) async {
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => _RenameDialog(initial: s.title),
    );
    if (!mounted) return;
    if (newTitle == null || newTitle.isEmpty || newTitle == s.title) return;
    try {
      final repo = await ref.read(chatRepositoryProvider.future);
      await repo.renameSession(s.id, newTitle);
      ref.invalidate(sessionListProvider);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _delete(ChatSession s) async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.sidebarDeleteChatTitle),
        content: Text(l10n.sidebarDeleteChatBody(s.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final repo = await ref.read(chatRepositoryProvider.future);
      await repo.deleteSession(s.id);
      ref.invalidate(sessionListProvider);
      if (!mounted) return;
      if (widget.selectedSessionId == s.id) _go(AppRoutes.home);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _logout() async {
    final repo = await ref.read(authRepositoryProvider.future);
    await repo.logout();
    ref.invalidate(currentUserProvider);
    if (!mounted) return;
    context.go(AppRoutes.login);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final user = ref.watch(currentUserProvider);
    final sessions = ref.watch(sessionListProvider);
    final usage = ref.watch(usageMeProvider).valueOrNull;
    final searchFocus = ref.watch(sidebarSearchFocusProvider);

    return Container(
      width: widget.width,
      decoration: BoxDecoration(
        color: t.surface,
        border: BorderDirectional(end: BorderSide(color: t.border)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // ── Header ───────────────────────────────────────────────
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                NexusSpacing.lg,
                NexusSpacing.lg,
                NexusSpacing.lg,
                NexusSpacing.sm,
              ),
              child: Row(
                children: [
                  const NexusLogo(size: 30),
                  const SizedBox(width: NexusSpacing.sm),
                  const Expanded(child: NexusWordmark(fontSize: 18)),
                  if (widget.showClose != null)
                    IconButton(
                      tooltip: l10n.sidebarCloseMenu,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: widget.showClose,
                    ),
                ],
              ),
            ),

            // ── Workspace switcher ───────────────────────────────────
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                NexusSpacing.lg,
                0,
                NexusSpacing.lg,
                NexusSpacing.md,
              ),
              child: OrgSwitcher(onNavigated: widget.onNavigated),
            ),

            // ── New chat button ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.lg),
              child: NexusButton(
                label: l10n.sidebarNewChat,
                icon: Icons.add_rounded,
                loading: _creating,
                onPressed: _creating ? null : _newChat,
              ),
            ),
            const SizedBox(height: NexusSpacing.md),

            // ── Search ───────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.lg),
              child: TextField(
                controller: _search,
                focusNode: searchFocus,
                onChanged: _onSearchChanged,
                decoration: InputDecoration(
                  hintText: l10n.sidebarSearchHint,
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: l10n.sidebarClearSearch,
                          icon: const Icon(Icons.close_rounded, size: 16),
                          onPressed: _clearSearch,
                        ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
            const SizedBox(height: NexusSpacing.md),

            // ── Section header ───────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.lg),
              child: Row(
                children: [
                  Text(
                    l10n.sidebarChats,
                    style: TextStyle(
                      color: t.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 3,
                    ),
                  ),
                  const Spacer(),
                  if (sessions.value != null && sessions.value!.isNotEmpty)
                    Text(
                      '${_filtered(sessions.value!).length}',
                      style: TextStyle(color: t.textMuted, fontSize: 11),
                    ),
                ],
              ),
            ),
            const SizedBox(height: NexusSpacing.sm),

            // ── Sessions list ────────────────────────────────────────
            Expanded(
              child: sessions.when(
                loading: () => const _SessionSkeletons(),
                error: (e, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(NexusSpacing.lg),
                    child: Text(
                      context.describeError(e),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: t.textMuted, fontSize: 12),
                    ),
                  ),
                ),
                data: (list) {
                  final filtered = _filtered(list);
                  if (_search.text.trim().isNotEmpty) {
                    return _SearchResults(
                      chats: filtered,
                      selectedSessionId: widget.selectedSessionId,
                      results: _results,
                      searching: _searching,
                      error: _searchError,
                      onOpenChat: (id) => _go(AppRoutes.chat(id)),
                      onRename: _rename,
                      onDelete: _delete,
                    );
                  }
                  if (filtered.isEmpty) {
                    return Center(
                      child: Text(
                        l10n.sidebarNoChats,
                        style: TextStyle(color: t.textMuted, fontSize: 12),
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.sm),
                    itemCount: filtered.length,
                    itemBuilder: (_, i) {
                      final s = filtered[i];
                      final selected = widget.selectedSessionId == s.id;
                      return _SessionTile(
                        session: s,
                        selected: selected,
                        onTap: () => _go(AppRoutes.chat(s.id)),
                        onRename: () => _rename(s),
                        onDelete: () => _delete(s),
                      );
                    },
                  );
                },
              ),
            ),

            Divider(color: t.borderSubtle, height: 1),

            // ── Quick links ──────────────────────────────────────────
            _SidebarLink(
              icon: Icons.menu_book_rounded,
              label: l10n.sidebarDocuments,
              active: widget.location.startsWith(AppRoutes.documents),
              onTap: () => _go(AppRoutes.documents),
            ),
            _SidebarLink(
              icon: Icons.collections_bookmark_rounded,
              label: l10n.sidebarCollections,
              active: widget.location.startsWith(AppRoutes.collections),
              onTap: () => _go(AppRoutes.collections),
            ),
            _SidebarLink(
              icon: Icons.smart_toy_outlined,
              label: l10n.sidebarAssistants,
              active: widget.location.startsWith(AppRoutes.assistants),
              onTap: () => _go(AppRoutes.assistants),
            ),
            _SidebarLink(
              icon: Icons.psychology_outlined,
              label: l10n.sidebarMemory,
              active: widget.location.startsWith(AppRoutes.memory),
              onTap: () => _go(AppRoutes.memory),
            ),
            _SidebarLink(
              icon: Icons.settings_rounded,
              label: l10n.sidebarSettings,
              active: widget.location.startsWith(AppRoutes.settings),
              onTap: () => _go(AppRoutes.settings),
            ),

            // ── Usage meter ──────────────────────────────────────────
            Divider(color: t.borderSubtle, height: 1),
            UsageMeter(summary: usage, onTap: () => _go(AppRoutes.settings)),

            // ── Profile dropdown ─────────────────────────────────────
            user.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(NexusSpacing.lg),
                child: SizedBox(
                  height: 16,
                  child: Skeleton(width: double.infinity, height: 16),
                ),
              ),
              error: (_, __) => const SizedBox.shrink(),
              data: (u) {
                if (u == null) return const SizedBox.shrink();
                return PopupMenuButton<String>(
                  offset: const Offset(0, -56),
                  onSelected: (v) {
                    if (v == 'settings') _go(AppRoutes.settings);
                    if (v == 'logout') _logout();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'settings', child: Text(l10n.sidebarSettings)),
                    PopupMenuItem(value: 'logout', child: Text(l10n.sidebarSignOut)),
                  ],
                  child: Container(
                    padding: const EdgeInsets.all(NexusSpacing.md),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: t.border)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: const BoxDecoration(
                            gradient: NexusColors.redGradient,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            u.email.substring(0, 1).toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        const SizedBox(width: NexusSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                u.fullName?.isNotEmpty == true
                                    ? u.fullName!
                                    : u.email.split('@').first,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: t.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                u.email,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: t.textMuted, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.unfold_more_rounded, color: t.textMuted, size: 18),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  List<ChatSession> _filtered(List<ChatSession> all) {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((s) => s.title.toLowerCase().contains(q)).toList();
  }
}

/// Search mode of the sidebar: chats whose title matches, then the
/// server's message hits ("MESSAGES") with their `<mark>` highlights.
class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.chats,
    required this.selectedSessionId,
    required this.results,
    required this.searching,
    required this.error,
    required this.onOpenChat,
    required this.onRename,
    required this.onDelete,
  });

  final List<ChatSession> chats;
  final String? selectedSessionId;
  final List<SearchResult>? results;
  final bool searching;
  final String? error;
  final ValueChanged<String> onOpenChat;
  final ValueChanged<ChatSession> onRename;
  final ValueChanged<ChatSession> onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final hits = results;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.sm),
      children: [
        if (chats.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.sm, vertical: 6),
            child: Text(
              l10n.sidebarNoTitleMatch,
              style: TextStyle(color: t.textMuted, fontSize: 12),
            ),
          )
        else
          for (final s in chats)
            _SessionTile(
              session: s,
              selected: selectedSessionId == s.id,
              onTap: () => onOpenChat(s.id),
              onRename: () => onRename(s),
              onDelete: () => onDelete(s),
            ),
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(
            NexusSpacing.sm,
            NexusSpacing.md,
            NexusSpacing.sm,
            6,
          ),
          child: Row(
            children: [
              Text(
                l10n.sidebarMessages,
                style: TextStyle(
                  color: t.textMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 3,
                ),
              ),
              const Spacer(),
              if (searching)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    valueColor: AlwaysStoppedAnimation(t.textMuted),
                  ),
                )
              else if (hits != null)
                Text('${hits.length}', style: TextStyle(color: t.textMuted, fontSize: 11)),
            ],
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.sm, vertical: 6),
            child: Text(error!, style: TextStyle(color: t.textMuted, fontSize: 12)),
          )
        else if (hits != null && hits.isEmpty && !searching)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.sm, vertical: 6),
            child: Text(
              l10n.sidebarNoMessagesMatch,
              style: TextStyle(color: t.textMuted, fontSize: 12),
            ),
          )
        else if (hits == null && !searching)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.sm, vertical: 6),
            child: Text(
              l10n.sidebarTypeTwoChars,
              style: TextStyle(color: t.textMuted, fontSize: 12),
            ),
          )
        else if (hits != null)
          for (final r in hits) _SearchResultTile(result: r, onTap: () => onOpenChat(r.sessionId)),
      ],
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({required this.result, required this.onTap});
  final SearchResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final snippet = result.highlight ?? result.snippet;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: const BorderRadius.all(NexusRadius.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.md, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      result.role == MessageRole.user
                          ? Icons.person_outline_rounded
                          : Icons.auto_awesome_rounded,
                      size: 12,
                      color: t.textMuted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        result.sessionTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                HighlightedText(
                  snippet,
                  maxLines: 2,
                  style: TextStyle(color: t.textMuted, fontSize: 12, height: 1.35),
                  markStyle: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.selected,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final ChatSession session;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: const BorderRadius.all(NexusRadius.md),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.md, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? NexusColors.crimson.withValues(alpha: 0.10) : Colors.transparent,
              borderRadius: const BorderRadius.all(NexusRadius.md),
              border: Border.all(
                color: selected ? NexusColors.crimson.withValues(alpha: 0.4) : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 15,
                  color: selected ? NexusColors.crimson : t.textMuted,
                ),
                const SizedBox(width: NexusSpacing.sm),
                Expanded(
                  child: Text(
                    session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? t.textPrimary : t.textSecondary,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: l10n.commonMore,
                  icon: Icon(Icons.more_horiz_rounded, size: 16, color: t.textMuted),
                  iconSize: 16,
                  padding: EdgeInsets.zero,
                  onSelected: (v) {
                    if (v == 'rename') onRename();
                    if (v == 'delete') onDelete();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'rename', child: Text(l10n.sidebarRename)),
                    PopupMenuItem(value: 'delete', child: Text(l10n.commonDelete)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarLink extends StatelessWidget {
  const _SidebarLink({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = active ? NexusColors.crimson : t.textSecondary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.lg, vertical: 14),
          child: Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: NexusSpacing.md),
              Text(
                label,
                style: TextStyle(
                  color: active ? t.textPrimary : t.textSecondary,
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionSkeletons extends StatelessWidget {
  const _SessionSkeletons();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.md, vertical: NexusSpacing.sm),
      itemCount: 6,
      itemBuilder: (_, __) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Skeleton(width: double.infinity, height: 32, radius: 10),
      ),
    );
  }
}

/// Rename dialog that owns its own [TextEditingController] and disposes it in
/// [State.dispose] — which Flutter calls only after the dialog's exit animation
/// finishes. Disposing the controller inline (right after `showDialog` returns)
/// crashes with a red screen, because the TextField is still mounted and using
/// the controller while the route animates out.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});
  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_ctrl.text.trim());

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.sidebarRenameChat),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: InputDecoration(hintText: l10n.sidebarChatNameHint),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}
