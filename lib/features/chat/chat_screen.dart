import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/breakpoints.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../shared/home_shell.dart';
import '../collections/collection_model.dart';
import '../collections/collections_repository.dart';
import '../models/model_info.dart';
import '../models/models_repository.dart';
import '../tools/tools_repository.dart';
import 'chat_controller.dart';
import 'chat_models.dart';
import 'chat_repository.dart';
import 'chat_sheets.dart';
import 'chat_widgets.dart';
import 'citation_sheet.dart';
import 'tool_chips.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  ChatController get _controller => ref.read(chatControllerProvider(widget.sessionId).notifier);

  Future<void> _pickTools(List<ToolInfo> tools) async {
    final current = _controller.effectiveToolNames ?? defaultToolSelection(tools);
    final result = await showToolPickerSheet(context, tools: tools, selected: current);
    if (result == null || !mounted) return;
    await _controller.setToolNames(result.names);
  }

  Future<void> _pickKnowledge(List<Collection> collections, List<String>? selected) async {
    final result = await showCollectionPickerSheet(
      context,
      collections: collections,
      selectedIds: selected,
    );
    if (result == null || !mounted) return;
    await _controller.setCollectionIds(result.ids);
  }

  /// `call_id`s of the tool rows directly above message [i] — those runs are
  /// rendered as standalone chips, so the assistant strip must skip them.
  static Set<String> _toolRowIdsBefore(List<ChatMessage> msgs, int i) {
    final ids = <String>{};
    for (var j = i - 1; j >= 0 && msgs[j].isToolRun; j--) {
      for (final tc in msgs[j].toolCalls) {
        if (tc.callId != null) ids.add(tc.callId!);
      }
    }
    return ids;
  }

  String _knowledgeLabel(List<Collection> collections, List<String>? ids) {
    if (ids == null) return 'Knowledge · All';
    if (ids.isEmpty) return 'Knowledge · None';
    final names = [
      for (final id in ids)
        for (final c in collections)
          if (c.id == id) c.name,
    ];
    if (names.length == 1) return 'Knowledge · ${names.single}';
    return 'Knowledge · ${ids.length} collection${ids.length == 1 ? '' : 's'}';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final state = ref.watch(chatControllerProvider(widget.sessionId));
    final controller = _controller;
    final listed = ref
        .watch(sessionListProvider)
        .valueOrNull
        ?.where((s) => s.id == widget.sessionId)
        .firstOrNull;
    final session = state.session ?? listed;
    final catalog = ref.watch(modelCatalogProvider).valueOrNull ?? ModelCatalog.empty;
    final defaultModelId = ref.watch(defaultModelIdProvider);
    final tools = ref.watch(toolCatalogProvider).valueOrNull;
    final collections = ref.watch(collectionListProvider).valueOrNull;

    ref.listen(chatControllerProvider(widget.sessionId), (_, __) => _scrollToBottom());

    final lastAssistantId = state.messages.lastWhere(
      (m) => m.role == MessageRole.assistant,
      orElse: () => ChatMessage(
        id: '',
        sessionId: '',
        role: MessageRole.assistant,
        content: '',
        createdAt: DateTime.now(),
      ),
    ).id;

    final sessionModelId = session?.model ?? defaultModelId;
    final sessionModelLabel = catalog.labelFor(sessionModelId);
    final effectiveTools = controller.effectiveToolNames;

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        leading: context.isMobile ? const MenuButton() : null,
        title: Row(
          children: [
            const NexusLogo(size: 22),
            const SizedBox(width: NexusSpacing.sm),
            Flexible(
              child: Text(
                session?.title ?? 'Chat',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: t.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (catalog.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: NexusSpacing.xs),
              child: ModelMenuButton(
                catalog: catalog,
                currentId: sessionModelId,
                tooltip: 'Session model',
                enabled: !state.sending,
                onSelected: (id) {
                  if (id != null && id != session?.model) controller.setSessionModel(id);
                },
                child: _HeaderModelChip(label: sessionModelLabel),
              ),
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, size: 20),
            onPressed: state.sending ? null : controller.reload,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: state.messages.isEmpty && !state.sending
                ? const _EmptyChat()
                : Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 880),
                      child: ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.symmetric(vertical: NexusSpacing.lg),
                        itemCount: state.messages.length,
                        itemBuilder: (_, i) {
                          final m = state.messages[i];
                          if (m.isToolRun) {
                            // Persisted tool runs: chips between the user
                            // message and its reply — never a bubble.
                            return Padding(
                              key: ValueKey(m.id),
                              padding: const EdgeInsets.symmetric(
                                horizontal: NexusSpacing.lg,
                                vertical: NexusSpacing.xs,
                              ),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: ToolCallChips(calls: m.toolCalls),
                              ),
                            );
                          }
                          final isAssistant = m.role == MessageRole.assistant;
                          final isLastAssistant = isAssistant && m.id == lastAssistantId;
                          final approvalId = m.approval?.approvalId;
                          return MessageBubble(
                            key: ValueKey(m.id),
                            message: m,
                            isLastAssistant: isLastAssistant && !state.sending,
                            onRegenerate: state.sending ? null : controller.regenerate,
                            hiddenToolCallIds:
                                isAssistant ? _toolRowIdsBefore(state.messages, i) : const {},
                            onApprovalDecision: approvalId == null || state.sending
                                ? null
                                : (d) => controller.resolveApproval(approvalId, d),
                            approvalBusy: state.sending,
                            onCitationTap: (c) => showCitationSheet(context, c),
                          );
                        },
                      ),
                    ),
                  ),
          ),
          if (state.error != null)
            Container(
              width: double.infinity,
              color: NexusColors.crimsonDark.withValues(alpha: 0.18),
              padding: const EdgeInsets.symmetric(
                horizontal: NexusSpacing.lg,
                vertical: NexusSpacing.sm,
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, size: 14, color: NexusColors.crimson),
                  const SizedBox(width: NexusSpacing.sm),
                  Expanded(
                    child: Text(
                      state.error!,
                      style: TextStyle(color: t.textPrimary, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: Composer(
                onSend: controller.send,
                sending: state.sending,
                stopping: state.stopping,
                useRag: state.useRag,
                useTools: state.useTools,
                onToggleRag: controller.toggleRag,
                onToggleTools: controller.toggleTools,
                onStop: controller.stop,
                toolsSummary: tools == null || tools.isEmpty || effectiveTools == null
                    ? null
                    : '${effectiveTools.length}/${tools.length}',
                onPickTools: tools == null || tools.isEmpty ? null : () => _pickTools(tools),
                knowledgeLabel: collections == null || collections.isEmpty
                    ? null
                    : _knowledgeLabel(collections, state.collectionIds),
                onPickKnowledge: collections == null || collections.isEmpty
                    ? null
                    : () => _pickKnowledge(collections, state.collectionIds),
                modelChip: catalog.isEmpty
                    ? null
                    : ModelMenuButton(
                        catalog: catalog,
                        currentId: state.modelOverride,
                        defaultEntry: 'Session model ($sessionModelLabel)',
                        tooltip: 'Model for the next message',
                        onSelected: controller.setModelOverride,
                        child: ComposerChip(
                          label: state.modelOverride == null
                              ? sessionModelLabel
                              : catalog.labelFor(state.modelOverride),
                          active: state.modelOverride != null,
                          icon: Icons.memory_rounded,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderModelChip extends StatelessWidget {
  const _HeaderModelChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: t.surfaceHigh,
        borderRadius: const BorderRadius.all(NexusRadius.pill),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.memory_rounded, size: 13, color: NexusColors.crimson),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.textPrimary, fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 2),
          Icon(Icons.expand_more_rounded, size: 14, color: t.textMuted),
        ],
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(NexusSpacing.xxl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const NexusLogo(size: 64),
              const SizedBox(height: NexusSpacing.lg),
              Text(
                'How can I help today?',
                style: TextStyle(
                  color: t.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: NexusSpacing.sm),
              Text(
                'Ask anything. Toggle RAG to ground answers in your documents, pick the Knowledge '
                'collections to search, or let NexusBot run tools for you.',
                textAlign: TextAlign.center,
                style: TextStyle(color: t.textSecondary, fontSize: 13.5, height: 1.5),
              ),
              const SizedBox(height: NexusSpacing.xl),
              const Wrap(
                spacing: NexusSpacing.sm,
                runSpacing: NexusSpacing.sm,
                alignment: WrapAlignment.center,
                children: [
                  _SuggestionChip(icon: Icons.menu_book_rounded, label: 'Summarize a document'),
                  _SuggestionChip(icon: Icons.code_rounded, label: 'Explain a code snippet'),
                  _SuggestionChip(icon: Icons.lightbulb_outline_rounded, label: 'Brainstorm ideas'),
                  _SuggestionChip(icon: Icons.translate_rounded, label: 'Translate text'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: t.surfaceHigh,
        borderRadius: const BorderRadius.all(NexusRadius.pill),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: NexusColors.crimson),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(color: t.textSecondary, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
