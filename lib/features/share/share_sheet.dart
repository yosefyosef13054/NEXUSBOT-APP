import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:share_plus/share_plus.dart';

import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import 'share_model.dart';
import 'share_repository.dart';

/// Expiry choices for a new link (hours).
const shareExpiryHours = [24, 24 * 7, 24 * 30, 24 * 365];

/// Translated label of one of [shareExpiryHours].
String shareExpiryLabel(AppLocalizations l10n, int hours) => switch (hours) {
      24 => l10n.shareExpiry1Day,
      168 => l10n.shareExpiry7Days,
      720 => l10n.shareExpiry30Days,
      _ => l10n.shareExpiry1Year,
    };

/// Opens the share-links sheet of a conversation: create a read-only link
/// (shown once, with copy + system share), list the active ones with their
/// view counts, revoke one or all.
Future<void> showShareLinksSheet(BuildContext context, {required String sessionId}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.tokens.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: NexusRadius.xl),
    ),
    builder: (_) => ShareLinksSheet(sessionId: sessionId),
  );
}

class ShareLinksSheet extends ConsumerStatefulWidget {
  const ShareLinksSheet({super.key, required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<ShareLinksSheet> createState() => _ShareLinksSheetState();
}

class _ShareLinksSheetState extends ConsumerState<ShareLinksSheet> {
  List<ShareLink>? _links;
  String? _loadError;
  bool _creating = false;
  int _expiryHours = shareExpiryHours[1];

  /// The link just created — its URL is only known now.
  ShareLink? _created;
  String? _createdUrl;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final repo = await ref.read(shareRepositoryProvider.future);
      final links = await repo.listShares(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _links = links;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = context.describeError(e));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _create() async {
    setState(() => _creating = true);
    try {
      final repo = await ref.read(shareRepositoryProvider.future);
      final link = await repo.createShare(widget.sessionId, expiresInHours: _expiryHours);
      if (!mounted) return;
      setState(() {
        _created = link;
        _createdUrl = link.url == null ? null : repo.resolveShareUrl(link.url!).toString();
        _copied = false;
      });
      await _load();
    } catch (e) {
      if (mounted) _toast(context.describeError(e));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _copy() async {
    final url = _createdUrl;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  Future<void> _systemShare() async {
    final url = _createdUrl;
    if (url == null) return;
    final l10n = context.l10n;
    try {
      await SharePlus.instance
          .share(ShareParams(uri: Uri.parse(url), title: l10n.shareNexusBotChat));
    } catch (e) {
      _toast(l10n.shareSheetFailed('$e'));
    }
  }

  Future<void> _revoke(ShareLink? link) async {
    try {
      final repo = await ref.read(shareRepositoryProvider.future);
      await repo.revokeShares(widget.sessionId, shareId: link?.id);
      if (!mounted) return;
      if (link == null || link.id == _created?.id) {
        setState(() {
          _created = null;
          _createdUrl = null;
        });
      }
      await _load();
    } catch (e) {
      if (mounted) _toast(context.describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    final links = _links;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.all(NexusSpacing.lg),
          child: ListView(
            shrinkWrap: true,
            children: [
              Text(
                l10n.shareTitle,
                style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(l10n.shareBody, style: TextStyle(color: t.textSecondary, fontSize: 12.5)),
              const SizedBox(height: NexusSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: InputDecorator(
                      decoration: InputDecoration(labelText: l10n.shareExpiresIn, isDense: true),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          isExpanded: true,
                          isDense: true,
                          value: _expiryHours,
                          items: [
                            for (final hours in shareExpiryHours)
                              DropdownMenuItem(
                                value: hours,
                                child: Text(shareExpiryLabel(l10n, hours)),
                              ),
                          ],
                          onChanged: _creating
                              ? null
                              : (v) => setState(() => _expiryHours = v ?? _expiryHours),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: NexusSpacing.md),
                  FilledButton.icon(
                    onPressed: _creating ? null : _create,
                    style: FilledButton.styleFrom(backgroundColor: NexusColors.crimson),
                    icon: _creating
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.link_rounded, size: 16),
                    label: Text(_creating ? l10n.shareCreating : l10n.shareCreateLink),
                  ),
                ],
              ),
              if (_created != null) ...[
                const SizedBox(height: NexusSpacing.md),
                Container(
                  padding: const EdgeInsets.all(NexusSpacing.md),
                  decoration: BoxDecoration(
                    color: NexusColors.crimson.withValues(alpha: 0.08),
                    borderRadius: const BorderRadius.all(NexusRadius.md),
                    border: Border.all(color: NexusColors.crimson.withValues(alpha: 0.4)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.shareCreatedNotice,
                        style: TextStyle(
                          color: t.textPrimary,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: NexusSpacing.xs),
                      SelectableText(
                        _createdUrl ?? _created!.token ?? '',
                        textDirection: TextDirection.ltr,
                        style: TextStyle(color: t.textSecondary, fontSize: 12.5),
                      ),
                      const SizedBox(height: NexusSpacing.sm),
                      Row(
                        children: [
                          TextButton.icon(
                            onPressed: _copy,
                            icon: Icon(
                              _copied ? Icons.check_rounded : Icons.copy_rounded,
                              size: 16,
                              color: _copied ? NexusColors.success : null,
                            ),
                            label: Text(_copied ? l10n.commonCopied : l10n.commonCopy),
                          ),
                          TextButton.icon(
                            onPressed: _systemShare,
                            icon: const Icon(Icons.ios_share_rounded, size: 16),
                            label: Text(l10n.shareSystemShare),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: NexusSpacing.lg),
              Row(
                children: [
                  Text(
                    l10n.shareActiveLinks,
                    style: TextStyle(
                      color: t.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 3,
                    ),
                  ),
                  const Spacer(),
                  if (links != null && links.length > 1)
                    TextButton(
                      onPressed: () => _revoke(null),
                      child: Text(l10n.shareRevokeAll),
                    ),
                ],
              ),
              if (_loadError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: NexusSpacing.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _loadError!,
                          style: TextStyle(color: t.textSecondary, fontSize: 12.5),
                        ),
                      ),
                      TextButton(onPressed: _load, child: Text(l10n.commonRetry)),
                    ],
                  ),
                )
              else if (links == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: NexusSpacing.md),
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: NexusColors.crimson),
                    ),
                  ),
                )
              else if (links.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: NexusSpacing.sm),
                  child: Text(
                    l10n.shareNoActive,
                    style: TextStyle(color: t.textMuted, fontSize: 12.5),
                  ),
                )
              else
                for (final link in links)
                  ShareLinkTile(
                    link: link,
                    highlighted: link.id == _created?.id,
                    onRevoke: () => _revoke(link),
                  ),
              const SizedBox(height: NexusSpacing.sm),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.commonDone),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One active link: expiry, views and a revoke button.
class ShareLinkTile extends StatelessWidget {
  const ShareLinkTile({
    super.key,
    required this.link,
    required this.onRevoke,
    this.highlighted = false,
  });

  final ShareLink link;
  final VoidCallback onRevoke;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toString();
    final expires = DateFormat.yMMMd(locale).add_jm().format(link.expiresAt.toLocal());
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        Icons.link_rounded,
        size: 18,
        color: highlighted ? NexusColors.crimson : t.textSecondary,
      ),
      title: Text(
        link.isExpired ? l10n.shareExpired(expires) : l10n.shareExpires(expires),
        style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle:
          Text(l10n.shareViews(link.views), style: TextStyle(color: t.textMuted, fontSize: 12)),
      trailing: IconButton(
        tooltip: l10n.shareRevoke,
        icon: Icon(Icons.link_off_rounded, size: 18, color: t.textSecondary),
        onPressed: onRevoke,
      ),
    );
  }
}
