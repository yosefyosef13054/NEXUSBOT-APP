import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/env.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';

/// `/legal` — the privacy policy and the terms of service (a short
/// template; the operator of a deployment replaces the wording). Reachable
/// before signing in (login / register) and from Settings → About.
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  /// Date of the template's last revision (shown on screen).
  static final lastUpdated = DateTime(2026, 11, 1);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.tokens;
    final date = MaterialLocalizations.of(context).formatMediumDate(lastUpdated);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: t.background,
        appBar: AppBar(
          leading: IconButton(
            tooltip: l10n.commonClose,
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => context.canPop() ? context.pop() : context.go('/'),
          ),
          title: Text(l10n.legalTitle, style: TextStyle(color: t.textPrimary)),
          bottom: TabBar(
            indicatorColor: NexusColors.crimson,
            labelColor: t.textPrimary,
            unselectedLabelColor: t.textMuted,
            tabs: [Tab(text: l10n.legalPrivacyTab), Tab(text: l10n.legalTermsTab)],
          ),
        ),
        body: TabBarView(
          children: [
            _LegalText(
              updated: l10n.legalUpdated(date),
              paragraphs: [
                l10n.legalPrivacyP1(Env.apiBaseUrl),
                l10n.legalPrivacyP2,
                l10n.legalPrivacyP3,
                l10n.legalPrivacyP4,
              ],
            ),
            _LegalText(
              updated: l10n.legalUpdated(date),
              paragraphs: [
                l10n.legalTermsP1,
                l10n.legalTermsP2,
                l10n.legalTermsP3,
                l10n.legalTermsP4,
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LegalText extends StatelessWidget {
  const _LegalText({required this.updated, required this.paragraphs});
  final String updated;
  final List<String> paragraphs;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(NexusSpacing.xl),
          children: [
            Text(updated, style: TextStyle(color: t.textMuted, fontSize: 12)),
            const SizedBox(height: NexusSpacing.lg),
            for (final p in paragraphs) ...[
              SelectableText(
                p,
                style: TextStyle(color: t.textPrimary, fontSize: 14.5, height: 1.6),
              ),
              const SizedBox(height: NexusSpacing.lg),
            ],
          ],
        ),
      ),
    );
  }
}
