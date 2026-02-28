// lib/hippa/hipaa_friendly_page.dart
import 'package:flutter/material.dart';
import 'package:transcript/common/app_flushbar.dart';
import 'package:transcript/widgets/icon_pill_button.dart';

// ✅ Glass primitives (same family as RecordSheet / TrashPage)
import '../ui/glass/glass_background.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';

class HipaaFriendlyPage extends StatelessWidget {
  const HipaaFriendlyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
  

    final fg = GlassTokens.fg(context, alpha: 0.92);
 
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GlassBackground(
        child: SafeArea(
          child: Column(
            children: [
              // ✅ Header (no AppBar panel)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  children: [
                    IconPillButton(
                      tooltip: 'Back',
                      icon: Icons.arrow_back,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'HIPAA-friendly architecture',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.2,
                          color: fg,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconPillButton(
                      tooltip: 'Info',
                      icon: Icons.info_outline,
                      onTap: () {
                        AppFlushbar.info(
                          context,
                          message: 'This is informational, not legal advice',
                        );
                      },
                    ),
                  ],
                ),
              ),

              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: GlassDivider(height: 1, thickness: 0.8),
              ),
              const SizedBox(height: 10),

              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  child: Column(
                    children: [
                      const _HipaaInfoCard(),
                      const SizedBox(height: 12),

                      // ✅ Single scroll view only (prevents weird nested scroll/layout issues)
                      Expanded(
                        child: ListView(
                          physics: const BouncingScrollPhysics(),
                          children: const [
                            _GlassSection(
                              title: 'Important note',
                              bullets: [
                                'We do not claim HIPAA certification.',
                                'HIPAA compliance depends on how you use the app, your policies, and your environment.',
                                'This page explains design choices that can help reduce privacy risk.',
                              ],
                            ),
                            SizedBox(height: 14),
                            _GlassSection(
                              title: 'Privacy-first by default',
                              bullets: [
                                'Transcription is processed on-device (no transcript required to be sent to us).',
                                'Your transcripts are stored locally on your device unless you choose to export/share them.',
                                'You control what you share and where you share it.',
                              ],
                            ),
                            SizedBox(height: 14),
                            _GlassSection(
                              title: 'Data minimization',
                              bullets: [
                                'We store only account-related data needed to verify purchases.',
                                'You can delete transcripts (Trash keeps them temporarily for recovery).',
                                'Optional features (like auto-email) are user-controlled and can be turned off.',
                              ],
                            ),
                            SizedBox(height: 14),
                            _GlassSection(
                              title: 'Security-minded workflow',
                              bullets: [
                                'If you export/share files, treat them as sensitive and store them in approved systems.',
                                'Use device lock + OS encryption and keep your phone updated.',
                                'Avoid sharing PHI in unsupported channels (public email inboxes, unsecured storage, etc.).',
                              ],
                            ),
                            SizedBox(height: 14),
                            _GlassSection(
                              title: 'What we are NOT promising',
                              bullets: [
                                'No “HIPAA certified” claims.',
                                'No guarantee of compliance for your organization.',
                                'No replacement for legal/compliance review.',
                              ],
                            ),
                            SizedBox(height: 72),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HipaaInfoCard extends StatelessWidget {
  const _HipaaInfoCard();

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context, alpha: 0.92);

    return GlassCard(
      variant: GlassCardVariant.tile,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: Colors.white.withValues(alpha: 0.06),
              border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            ),
            child: Icon(Icons.privacy_tip_outlined, color: fg),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Designed to reduce risk',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: fg,
                    letterSpacing: -0.1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'We aim for a privacy-first architecture that can support HIPAA-conscious workflows when used appropriately.',
                  style: TextStyle(
                    color: GlassTokens.muted(context, alpha: 0.70),
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: const [
                    _MetaPill(text: 'On-device'),
                    _MetaPill(text: 'Local storage'),
                    _MetaPill(text: 'User-controlled export'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassSection extends StatelessWidget {
  const _GlassSection({required this.title, required this.bullets});

  final String title;
  final List<String> bullets;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context, alpha: 0.92);

    return GlassCard(
      variant: GlassCardVariant.tile,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 13,
              color: fg,
            ),
          ),
          const SizedBox(height: 10),
          for (final t in bullets) _GlassBullet(text: t),
        ],
      ),
    );
  }
}

class _GlassBullet extends StatelessWidget {
  const _GlassBullet({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(
              Icons.circle,
              size: 7,
              color: isDark ? Colors.white70 : Colors.black54,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white70 : Colors.black87,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.text, this.accent});
  final String text;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final c = accent;

    return Container(
      height: 30,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: (c ?? Colors.white).withValues(alpha: 0.06),
        border: Border.all(color: (c ?? Colors.white).withValues(alpha: 0.12)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: c != null ? c.withValues(alpha: 0.95) : Colors.white70,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}