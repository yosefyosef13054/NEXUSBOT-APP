import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/breakpoints.dart';
import '../../core/file_sink.dart';
import '../../core/preferences.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../l10n/l10n.dart';
import '../../l10n/labels.dart';
import '../../shared/home_shell.dart';
import '../assistants/assistant_model.dart';
import '../assistants/assistant_picker.dart';
import '../assistants/assistants_repository.dart';
import '../attachments/attachment_picker.dart';
import '../attachments/attachment_widgets.dart';
import '../attachments/attachments_repository.dart';
import '../collections/collection_model.dart';
import '../collections/collections_repository.dart';
import '../models/model_info.dart';
import '../models/models_repository.dart';
import '../share/share_model.dart';
import '../share/share_repository.dart';
import '../share/share_sheet.dart';
import '../share_intake/share_intake.dart';
import '../tools/tools_repository.dart';
import '../usage/usage_repository.dart';
import '../usage/usage_widgets.dart';
import '../voice/recorder.dart';
import '../voice/voice_button.dart';
import '../voice/voice_models.dart';
import '../voice/voice_repository.dart';
import 'chat_controller.dart';
import 'chat_models.dart';
import 'chat_repository.dart';
import 'chat_sheets.dart';
import 'chat_widgets.dart';
import 'citation_sheet.dart';
import 'tool_chips.dart';

enum _ChatMenuAction { exportMarkdown, exportJson, copyText, share }

/// Desktop and web get "Enter sends, Shift+Enter inserts a newline".
bool get enterSendsOnThisPlatform =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows;

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.sessionId, this.attachGenerationId});
  final String sessionId;

  /// A generation to attach to on open (from a `generation_done` push
  /// notification: `/chat/:id?generation=<gid>`).
  final String? attachGenerationId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _scrollCtrl = ScrollController();
  final _composer = TextEditingController();
  final _composerFocus = FocusNode(debugLabel: 'composer');

  /// The user message currently open in the inline editor.
  String? _editingId;
  bool _quotaRefreshing = false;

  @override
  void initState() {
    super.initState();
    _attachFromRoute(widget.attachGenerationId);
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumeDraft());
  }

  @override
  void didUpdateWidget(ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.attachGenerationId != oldWidget.attachGenerationId) {
      _attachFromRoute(widget.attachGenerationId);
    }
  }

  void _attachFromRoute(String? generationId) {
    if (generationId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.attachToGeneration(generationId);
    });
  }

  /// "Share to NexusBot": the draft parked for this chat fills the composer
  /// and its files are uploaded as attachments.
  Future<void> _consumeDraft() async {
    if (!mounted) return;
    final draft = ref.read(composerDraftProvider);
    if (draft == null || draft.sessionId != widget.sessionId) return;
    ref.read(composerDraftProvider.notifier).state = null;
    final text = draft.text?.trim() ?? '';
    if (text.isNotEmpty) {
      _composer
        ..text = text
        ..selection = TextSelection.collapsed(offset: text.length);
    }
    for (final file in draft.files) {
      await _controller.attachFile(bytes: file.bytes, filename: file.filename);
      if (!mounted) return;
    }
    _composerFocus.requestFocus();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _composer.dispose();
    _composerFocus.dispose();
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

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

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

  /// Thumbs up / down: tapping the active rating clears it; a thumbs-down
  /// first asks for an optional comment.
  Future<void> _rate(ChatMessage m, int rating) async {
    if (m.feedback?.rating == rating) {
      await _controller.clearFeedback(m.id);
      return;
    }
    if (rating < 0) {
      final result = await showFeedbackCommentSheet(context);
      if (result == null || !mounted) return;
      await _controller.setFeedback(m.id, rating, comment: result.comment);
      return;
    }
    await _controller.setFeedback(m.id, rating);
  }

  Future<void> _refreshQuota() async {
    setState(() => _quotaRefreshing = true);
    try {
      await _controller.refreshQuota();
    } catch (_) {
      // The banner stays; the error is not worth a second banner.
    } finally {
      if (mounted) setState(() => _quotaRefreshing = false);
    }
  }

  // ── Attachments ────────────────────────────────────────────────────────

  Future<void> _attach(AttachmentSource source) async {
    final PickedAttachment? picked;
    try {
      picked = await ref.read(attachmentPickerProvider).pick(source);
    } catch (e) {
      if (mounted) _toast(context.l10n.chatPickerFailed('$e'));
      return;
    }
    if (picked == null || !mounted) return;
    await _controller.attachFile(bytes: picked.bytes, filename: picked.filename);
  }

  /// Downloads an attachment / artifact and hands it to the platform
  /// (share sheet or browser download).
  Future<void> _download(Attachment a) async {
    try {
      final content = await ref.read(attachmentContentLoaderProvider).load(a.url);
      await ref.read(fileSinkProvider).save(
            bytes: content.bytes,
            filename: a.name,
            mimeType: content.mimeType.isEmpty ? a.mimeType : content.mimeType,
          );
    } catch (e) {
      if (mounted) _toast(context.describeError(e));
    }
  }

  Future<void> _open(Attachment a) async {
    if (a.isRenderableImage) {
      await showAttachmentViewer(context, a, onDownload: () => _download(a));
      return;
    }
    await _download(a);
  }

  // ── Export & share ────────────────────────────────────────────────────

  Future<void> _export(ExportFormat format) async {
    try {
      final repo = await ref.read(shareRepositoryProvider.future);
      final file = await repo.export(widget.sessionId, format: format);
      await ref.read(fileSinkProvider).save(
            bytes: file.bytes,
            filename: file.filename,
            mimeType: file.mimeType,
          );
      if (mounted) _toast(context.l10n.chatExported(file.filename));
    } catch (e) {
      if (mounted) _toast(context.describeError(e));
    }
  }

  /// The visible branch as plain text on the clipboard (no server round
  /// trip, works offline).
  Future<void> _copyAsText() async {
    final messages = ref.read(chatControllerProvider(widget.sessionId)).messages;
    final text = plainTextTranscript(messages);
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _toast(context.l10n.chatCopiedToClipboard);
  }

  /// `You: …` / `NexusBot: …` blocks, tool rows skipped.
  static String plainTextTranscript(List<ChatMessage> messages) => [
        for (final m in messages)
          if (!m.isToolRun && !m.streaming && m.content.isNotEmpty)
            '${m.role == MessageRole.user ? 'You' : 'NexusBot'}:\n${m.content}',
      ].join('\n\n');

  void _onMenu(_ChatMenuAction action) {
    switch (action) {
      case _ChatMenuAction.exportMarkdown:
        _export(ExportFormat.markdown);
      case _ChatMenuAction.exportJson:
        _export(ExportFormat.json);
      case _ChatMenuAction.copyText:
        _copyAsText();
      case _ChatMenuAction.share:
        showShareLinksSheet(context, sessionId: widget.sessionId);
    }
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

  String _knowledgeLabel(AppLocalizations l10n, List<Collection> collections, List<String>? ids) {
    if (ids == null) return l10n.chatKnowledgeAll;
    if (ids.isEmpty) return l10n.chatKnowledgeNone;
    final names = [
      for (final id in ids)
        for (final c in collections)
          if (c.id == id) c.name,
    ];
    if (names.length == 1) return l10n.chatKnowledgeOne(names.single);
    return l10n.chatKnowledgeCount(ids.length);
  }

  /// A voice clip is being transcribed (the optimistic voice bubble is still
  /// pending).
  static bool _voiceInFlight(ChatState state) =>
      state.sending && state.messages.any((m) => m.isVoicePlaceholder);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
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
    final assistants = ref.watch(assistantListProvider).valueOrNull ?? const <Assistant>[];
    final assistant = session?.assistantId == null
        ? null
        : assistants.where((a) => a.id == session!.assistantId).firstOrNull;
    final quota = ref.watch(quotaStateProvider);
    final voice = ref.watch(voiceCapabilitiesProvider).valueOrNull ?? VoiceCapabilities.none;
    final prefs = ref.watch(prefsProvider);

    ref.listen(chatControllerProvider(widget.sessionId), (_, __) => _scrollToBottom());

    final lastAssistantId = state.messages
        .lastWhere(
          (m) => m.role == MessageRole.assistant,
          orElse: () => ChatMessage(
            id: '',
            sessionId: '',
            role: MessageRole.assistant,
            content: '',
            createdAt: DateTime.now(),
          ),
        )
        .id;

    final sessionModelId = session?.model ?? assistant?.model ?? defaultModelId;
    final sessionModelLabel = catalog.labelFor(sessionModelId);
    final effectiveTools = controller.effectiveToolNames;
    final busy = state.sending || state.switchingBranch;

    // Images need a vision model; an unknown model is left to the server.
    final effectiveModel = catalog.byId(state.modelOverride ?? sessionModelId);
    final canAttachImages = effectiveModel == null || effectiveModel.supportsVision;
    final imageAttachHint =
        canAttachImages ? null : l10n.chatVisionHint(effectiveModel.displayName);

    // One extra row at the top for "load earlier" / the cached notice.
    final hasHeader = state.hasOlder || state.loadingOlder || state.fromCache;
    final offset = hasHeader ? 1 : 0;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (state.sending) controller.stop();
        },
      },
      child: Scaffold(
        backgroundColor: t.background,
        appBar: AppBar(
          leading: context.isMobile ? const MenuButton() : null,
          title: Row(
            children: [
              const NexusLogo(size: 22),
              const SizedBox(width: NexusSpacing.sm),
              Flexible(
                child: Text(
                  session?.title ?? l10n.chatTitleFallback,
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
            if (assistants.isNotEmpty || session?.assistantId != null)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: NexusSpacing.xs),
                child: AssistantMenuButton(
                  assistants: assistants,
                  currentId: session?.assistantId,
                  enabled: !busy,
                  onSelected: (id) {
                    if (id != session?.assistantId) controller.setAssistant(id);
                  },
                  child: _HeaderAssistantChip(
                    assistant: assistant,
                    hasId: session?.assistantId != null,
                  ),
                ),
              ),
            if (catalog.isNotEmpty)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: NexusSpacing.xs),
                child: ModelMenuButton(
                  catalog: catalog,
                  currentId: sessionModelId,
                  tooltip: l10n.chatSessionModelTooltip,
                  enabled: !busy,
                  onSelected: (id) {
                    if (id != null && id != session?.model) controller.setSessionModel(id);
                  },
                  child: _HeaderModelChip(label: sessionModelLabel),
                ),
              ),
            IconButton(
              tooltip: l10n.commonRefresh,
              icon: const Icon(Icons.refresh_rounded, size: 20),
              onPressed: busy ? null : controller.reload,
            ),
            PopupMenuButton<_ChatMenuAction>(
              tooltip: l10n.chatActionsTooltip,
              icon: const Icon(Icons.more_vert_rounded, size: 20),
              onSelected: _onMenu,
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: _ChatMenuAction.exportMarkdown,
                  child: _MenuRow(icon: Icons.article_outlined, label: l10n.chatExportMarkdown),
                ),
                PopupMenuItem(
                  value: _ChatMenuAction.exportJson,
                  child: _MenuRow(icon: Icons.data_object_rounded, label: l10n.chatExportJson),
                ),
                PopupMenuItem(
                  value: _ChatMenuAction.copyText,
                  child: _MenuRow(icon: Icons.copy_all_rounded, label: l10n.chatCopyAsText),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: _ChatMenuAction.share,
                  child: _MenuRow(icon: Icons.link_rounded, label: l10n.chatShareLink),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: state.messages.isEmpty && !state.sending && !hasHeader
                  ? _EmptyChat(assistant: assistant)
                  : Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 880),
                        child: ListView.builder(
                          controller: _scrollCtrl,
                          padding: const EdgeInsets.symmetric(vertical: NexusSpacing.lg),
                          itemCount: state.messages.length + offset,
                          itemBuilder: (_, index) {
                            if (hasHeader && index == 0) {
                              return _HistoryHeader(
                                hasOlder: state.hasOlder,
                                loading: state.loadingOlder,
                                fromCache: state.fromCache,
                                onLoadOlder: controller.loadOlder,
                              );
                            }
                            final i = index - offset;
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
                                  alignment: AlignmentDirectional.centerStart,
                                  child: ToolCallChips(calls: m.toolCalls),
                                ),
                              );
                            }
                            final isAssistant = m.role == MessageRole.assistant;
                            final isUser = m.role == MessageRole.user;
                            final isLastAssistant = isAssistant && m.id == lastAssistantId;
                            final approvalId = m.approval?.approvalId;
                            return MessageBubble(
                              key: ValueKey(m.id),
                              message: m,
                              isLastAssistant: isLastAssistant && !state.sending,
                              onRegenerate: busy ? null : controller.regenerate,
                              hiddenToolCallIds:
                                  isAssistant ? _toolRowIdsBefore(state.messages, i) : const {},
                              onApprovalDecision: approvalId == null || busy
                                  ? null
                                  : (d) => controller.resolveApproval(approvalId, d),
                              approvalBusy: state.sending,
                              onCitationTap: (c) => showCitationSheet(context, c),
                              onEdit: isUser && !busy && quota == null && !m.isQueued
                                  ? () => setState(() => _editingId = m.id)
                                  : null,
                              editing: _editingId == m.id,
                              onSubmitEdit: (text) {
                                setState(() => _editingId = null);
                                controller.editMessage(m.id, text);
                              },
                              onCancelEdit: () => setState(() => _editingId = null),
                              onSwitchSibling:
                                  busy ? null : (delta) => controller.switchSibling(m.id, delta),
                              switchingBranch: state.switchingBranch,
                              onFeedback: isAssistant && !busy ? (r) => _rate(m, r) : null,
                              onMemoriesTap: () => context.go(AppRoutes.memory),
                              onOpenAttachment: _open,
                              onOpenArtifact: _open,
                              onPlayAudio: isAssistant && m.audio?.isPlayable == true
                                  ? () => controller.playMessageAudio(m)
                                  : null,
                              playingAudio: state.playingMessageId == m.id,
                              onRetrySend: m.isQueued ? () => controller.retryQueued(m.id) : null,
                              onCancelSend: m.isQueued ? () => controller.cancelQueued(m.id) : null,
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
                        state.error!.localized(l10n, context.describeError),
                        style: TextStyle(color: t.textPrimary, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            if (quota != null)
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: QuotaBanner(
                    quota: quota,
                    refreshing: _quotaRefreshing,
                    onRefresh: _refreshQuota,
                  ),
                ),
              ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: Composer(
                  controller: _composer,
                  focusNode: _composerFocus,
                  enterSends: enterSendsOnThisPlatform,
                  onSend: controller.send,
                  onSendBackground: controller.sendInBackground,
                  sending: state.sending,
                  stopping: state.stopping,
                  enabled: quota == null,
                  disabledHint: l10n.chatBudgetPaused,
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
                      : _knowledgeLabel(l10n, collections, state.collectionIds),
                  onPickKnowledge: collections == null || collections.isEmpty
                      ? null
                      : () => _pickKnowledge(collections, state.collectionIds),
                  attachments: state.pendingAttachments,
                  uploading: state.uploading,
                  onAttach: _attach,
                  onRemoveAttachment: (a) => controller.removeAttachment(a.id),
                  canAttachImages: canAttachImages,
                  imageAttachHint: imageAttachHint,
                  voiceButton: voice.sttAvailable
                      ? PushToTalkButton(
                          recorder: ref.watch(recorderProvider),
                          onClip: controller.sendVoice,
                          onError: _toast,
                          enabled: quota == null && !busy,
                          processing: _voiceInFlight(state),
                        )
                      : null,
                  speakReplies: voice.ttsAvailable ? prefs.speakReplies : null,
                  onToggleSpeak: ref.read(prefsProvider.notifier).setSpeakReplies,
                  modelChip: catalog.isEmpty
                      ? null
                      : ModelMenuButton(
                          catalog: catalog,
                          currentId: state.modelOverride,
                          defaultEntry: l10n.chatSessionModelEntry(sessionModelLabel),
                          tooltip: l10n.chatModelNextMessageTooltip,
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
      ),
    );
  }
}

/// Top row of the message list: "Load earlier messages" while the server
/// has older pages, and the cached-data notice while the chat shows the
/// device copy.
class _HistoryHeader extends StatelessWidget {
  const _HistoryHeader({
    required this.hasOlder,
    required this.loading,
    required this.fromCache,
    required this.onLoadOlder,
  });

  final bool hasOlder;
  final bool loading;
  final bool fromCache;
  final VoidCallback onLoadOlder;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: NexusSpacing.lg, vertical: NexusSpacing.xs),
      child: Column(
        children: [
          if (fromCache)
            Padding(
              padding: const EdgeInsets.only(bottom: NexusSpacing.xs),
              child: Text(
                l10n.chatShowingCached,
                textAlign: TextAlign.center,
                style: TextStyle(color: t.textMuted, fontSize: 11),
              ),
            ),
          if (loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: NexusSpacing.sm),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: t.textMuted),
                  ),
                  const SizedBox(width: NexusSpacing.sm),
                  Text(l10n.chatLoadingEarlier, style: TextStyle(color: t.textMuted, fontSize: 12)),
                ],
              ),
            )
          else if (hasOlder)
            Center(
              child: NexusGhostButton(
                label: l10n.chatLoadEarlier,
                icon: Icons.history_rounded,
                onPressed: onLoadOlder,
              ),
            ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16),
        const SizedBox(width: NexusSpacing.sm),
        Text(label),
      ],
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

/// Avatar + name of the session's assistant ("Plain chat" when none). An
/// assistant that is no longer listed (deleted) shows as "Assistant".
class _HeaderAssistantChip extends StatelessWidget {
  const _HeaderAssistantChip({required this.assistant, required this.hasId});
  final Assistant? assistant;
  final bool hasId;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final label = assistant?.name ?? (hasId ? l10n.chatAssistantFallback : l10n.chatPlainChat);
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(4, 3, 8, 3),
      decoration: BoxDecoration(
        color: t.surfaceHigh,
        borderRadius: const BorderRadius.all(NexusRadius.pill),
        border: Border.all(
          color: assistant == null ? t.border : NexusColors.crimson.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AssistantAvatar(assistant: assistant, size: 22),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
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
  const _EmptyChat({this.assistant});
  final Assistant? assistant;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final a = assistant;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(NexusSpacing.xxl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (a == null) const NexusLogo(size: 64) else AssistantAvatar(assistant: a, size: 64),
              const SizedBox(height: NexusSpacing.lg),
              Text(
                a == null ? l10n.chatEmptyTitle : a.name,
                style: TextStyle(
                  color: t.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: NexusSpacing.sm),
              Text(
                a?.description?.trim().isNotEmpty == true
                    ? a!.description!.trim()
                    : l10n.chatEmptyBody,
                textAlign: TextAlign.center,
                style: TextStyle(color: t.textSecondary, fontSize: 13.5, height: 1.5),
              ),
              const SizedBox(height: NexusSpacing.xl),
              Wrap(
                spacing: NexusSpacing.sm,
                runSpacing: NexusSpacing.sm,
                alignment: WrapAlignment.center,
                children: [
                  _SuggestionChip(icon: Icons.menu_book_rounded, label: l10n.chatSuggestSummarize),
                  _SuggestionChip(icon: Icons.code_rounded, label: l10n.chatSuggestExplainCode),
                  _SuggestionChip(icon: Icons.image_outlined, label: l10n.chatSuggestDescribePhoto),
                  _SuggestionChip(icon: Icons.translate_rounded, label: l10n.chatSuggestTranslate),
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
