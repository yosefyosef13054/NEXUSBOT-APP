import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api_exception.dart';
import '../../core/breakpoints.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../shared/home_shell.dart';
import '../auth/auth_providers.dart';
import 'admin_repository.dart';

/// `/admin/feedback` — every thumbs up / down users left, newest first,
/// with the comment and a shortcut to the chat. Server administrators only.
class AdminFeedbackScreen extends ConsumerStatefulWidget {
  const AdminFeedbackScreen({super.key});

  @override
  ConsumerState<AdminFeedbackScreen> createState() => _AdminFeedbackScreenState();
}

class _AdminFeedbackScreenState extends ConsumerState<AdminFeedbackScreen> {
  static const _pageSize = 50;

  final _items = <FeedbackEntry>[];
  int _page = 0;
  int _total = 0;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore(reset: true));
  }

  bool get _hasMore => _items.length < _total;

  Future<void> _loadMore({bool reset = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _items.clear();
        _page = 0;
        _total = 0;
      }
    });
    try {
      final repo = await ref.read(adminRepositoryProvider.future);
      final result = await repo.listFeedback(page: _page + 1, pageSize: _pageSize);
      if (!mounted) return;
      setState(() {
        _items.addAll(result.items);
        _page = result.page;
        _total = result.total;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final user = ref.watch(currentUserProvider).valueOrNull;

    final Widget body;
    if (user != null && !user.isServerAdmin) {
      body = const EmptyState(
        icon: Icons.lock_outline_rounded,
        title: 'Administrators only',
        subtitle: 'Feedback is available to server administrators.',
      );
    } else if (_error != null && _items.isEmpty) {
      body = EmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load feedback',
        subtitle: errorText(_error!),
        action: NexusGhostButton(
          label: 'Retry',
          icon: Icons.refresh_rounded,
          onPressed: () => _loadMore(reset: true),
        ),
      );
    } else if (_items.isEmpty && !_loading) {
      body = const EmptyState(
        icon: Icons.thumbs_up_down_outlined,
        title: 'No feedback yet',
        subtitle: 'Thumbs up / down left on replies show up here.',
      );
    } else {
      body = ListView.separated(
        padding: const EdgeInsets.all(NexusSpacing.lg),
        itemCount: _items.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: NexusSpacing.sm),
        itemBuilder: (_, i) {
          if (i == _items.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: NexusSpacing.md),
              child: Center(
                child: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child:
                            CircularProgressIndicator(strokeWidth: 2, color: NexusColors.crimson),
                      )
                    : _hasMore
                        ? NexusGhostButton(
                            label: 'Load more',
                            icon: Icons.expand_more_rounded,
                            onPressed: _loadMore,
                          )
                        : Text(
                            '${_items.length} of $_total',
                            style: TextStyle(color: t.textMuted, fontSize: 11),
                          ),
              ),
            );
          }
          final f = _items[i];
          return _FeedbackTile(
            entry: f,
            onOpenChat: () => context.go(AppRoutes.chat(f.sessionId)),
          );
        },
      );
    }

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        leading: context.isMobile ? const MenuButton() : null,
        title: Text('Feedback', style: TextStyle(color: t.textPrimary)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : () => _loadMore(reset: true),
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: body),
      ),
    );
  }
}

class _FeedbackTile extends StatelessWidget {
  const _FeedbackTile({required this.entry, required this.onOpenChat});
  final FeedbackEntry entry;
  final VoidCallback onOpenChat;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final f = entry;
    final color = f.isPositive ? NexusColors.success : NexusColors.danger;
    final when =
        f.createdAt == null ? '' : DateFormat.yMMMd().add_jm().format(f.createdAt!.toLocal());
    final comment = f.comment?.trim() ?? '';
    return Container(
      padding: const EdgeInsets.all(NexusSpacing.lg),
      decoration: BoxDecoration(
        color: t.surfaceHigh,
        borderRadius: const BorderRadius.all(NexusRadius.lg),
        border: Border.all(color: t.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: const BorderRadius.all(NexusRadius.md),
              border: Border.all(color: color.withValues(alpha: 0.5)),
            ),
            alignment: Alignment.center,
            child: Icon(
              f.isPositive ? Icons.thumb_up_alt_rounded : Icons.thumb_down_alt_rounded,
              size: 18,
              color: color,
            ),
          ),
          const SizedBox(width: NexusSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  comment.isEmpty ? 'No comment' : comment,
                  style: TextStyle(
                    color: comment.isEmpty ? t.textMuted : t.textPrimary,
                    fontSize: 13.5,
                    fontStyle: comment.isEmpty ? FontStyle.italic : FontStyle.normal,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    f.isPositive ? 'Thumbs up' : 'Thumbs down',
                    if (when.isNotEmpty) when,
                    if (f.userId.length >= 4) 'user …${f.userId.substring(f.userId.length - 4)}',
                  ].join(' · '),
                  style: TextStyle(color: t.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: NexusSpacing.sm),
          TextButton.icon(
            onPressed: f.sessionId.isEmpty ? null : onOpenChat,
            icon: const Icon(Icons.chat_bubble_outline_rounded, size: 14),
            label: const Text('Open chat'),
          ),
        ],
      ),
    );
  }
}
