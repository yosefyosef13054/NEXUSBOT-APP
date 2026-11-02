import '../features/chat/chat_models.dart';
import '../features/documents/document_model.dart';
import '../features/mcp/mcp_model.dart';
import '../features/memory/memory_model.dart';
import '../features/orgs/org_model.dart';
import '../features/usage/usage_model.dart';
import '../features/usage/usage_widgets.dart';
import 'generated/app_localizations.dart';

/// Translated labels for the enums the models expose. The models keep their
/// wire values and English fallbacks; screens render through these.
extension OrgRoleL10n on OrgRole {
  String localized(AppLocalizations l10n) => switch (this) {
        OrgRole.owner => l10n.roleOwner,
        OrgRole.admin => l10n.roleAdmin,
        OrgRole.member => l10n.roleMember,
      };
}

extension UsageMetricL10n on UsageMetric {
  String localized(AppLocalizations l10n) => switch (this) {
        UsageMetric.cost => l10n.usageMetricCost,
        UsageMetric.tokens => l10n.usageMetricTokens,
        UsageMetric.messages => l10n.usageMetricMessages,
      };
}

extension UsageGroupByL10n on UsageGroupBy {
  String localized(AppLocalizations l10n) => switch (this) {
        UsageGroupBy.user => l10n.usageGroupUser,
        UsageGroupBy.model => l10n.usageGroupModel,
        UsageGroupBy.day => l10n.usageGroupDay,
        UsageGroupBy.org => l10n.usageGroupOrg,
      };
}

extension MemoryKindL10n on MemoryKind {
  /// Section heading (plural).
  String localized(AppLocalizations l10n) => switch (this) {
        MemoryKind.fact => l10n.memoryKindFacts,
        MemoryKind.preference => l10n.memoryKindPreferences,
        MemoryKind.instruction => l10n.memoryKindInstructions,
      };

  /// Dropdown entry (singular).
  String localizedSingular(AppLocalizations l10n) => switch (this) {
        MemoryKind.fact => l10n.memoryKindFact,
        MemoryKind.preference => l10n.memoryKindPreference,
        MemoryKind.instruction => l10n.memoryKindInstruction,
      };
}

extension MCPTransportL10n on MCPTransport {
  String localized(AppLocalizations l10n) => switch (this) {
        MCPTransport.http => 'HTTP',
        MCPTransport.sse => 'SSE',
        MCPTransport.stdio => l10n.mcpTransportStdio,
      };
}

extension ToolCallStatusL10n on ToolCallStatus {
  String localized(AppLocalizations l10n) => switch (this) {
        ToolCallStatus.ok => l10n.toolStatusOk,
        ToolCallStatus.error => l10n.toolStatusError,
        ToolCallStatus.denied => l10n.toolStatusDenied,
        ToolCallStatus.unknown => l10n.toolStatusUnknown,
      };
}

extension DocumentStatusL10n on DocumentStatus {
  String localized(AppLocalizations l10n, {int? progress}) => switch (this) {
        DocumentStatus.pending => l10n.docStatusPending,
        DocumentStatus.processing =>
          progress == null ? l10n.docStatusIndexing : l10n.docStatusIndexingPct(progress),
        DocumentStatus.ready => l10n.docStatusReady,
        DocumentStatus.failed => l10n.docStatusFailed,
        DocumentStatus.unknown => '?',
      };
}

extension ChatErrorL10n on ChatError {
  /// The translated text for the banner above the composer; [describe]
  /// renders the thrown object of an [ChatErrorKind.exception].
  String localized(AppLocalizations l10n, String Function(Object error) describe) => switch (kind) {
        ChatErrorKind.message => message,
        ChatErrorKind.exception => error == null ? message : describe(error!),
        ChatErrorKind.busy => l10n.chatErrorBusy,
        ChatErrorKind.staleApproval => l10n.chatErrorStaleApproval,
        ChatErrorKind.voiceUnavailable => l10n.chatErrorVoiceUnavailable,
        ChatErrorKind.visionRequired => l10n.chatErrorVisionRequired(message, models.join(', ')),
      };
}
