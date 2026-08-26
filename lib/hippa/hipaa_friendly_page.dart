import 'package:flutter/material.dart';
import 'package:transcript/common/app_flushbar.dart';
import 'package:transcript/widgets/icon_pill_button.dart';

import '../ui/glass/glass_tokens.dart';

class HipaaFriendlyPage extends StatelessWidget {
  const HipaaFriendlyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);
    final primaryColor = GlassTokens.primary(context);

    return Scaffold(
      backgroundColor: GlassTokens.backgroundColor(context),
      body: SafeArea(
        child: Column(
          children: [
            // Top App Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  IconPillButton(
                    tooltip: 'Back',
                    icon: Icons.arrow_back_rounded,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'HIPAA-friendly architecture',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        color: fg,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconPillButton(
                    tooltip: 'Info',
                    icon: Icons.info_outline_rounded,
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

            Divider(
              height: 1,
              thickness: 1,
              color: GlassTokens.borderColor(context),
            ),

            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  // Top Info Banner Card
                  _HipaaInfoCard(
                    primaryColor: primaryColor,
                    fg: fg,
                    muted: muted,
                    isDark: isDark,
                  ),

                  const SizedBox(height: 20),

                  _SectionCard(
                    title: 'Important note',
                    icon: Icons.warning_amber_rounded,
                    iconColor: const Color(0xFFFF9500),
                    primaryColor: primaryColor,
                    isDark: isDark,
                    bullets: const [
                      'We do not claim HIPAA certification.',
                      'HIPAA compliance depends on how you use the app, your policies, and your environment.',
                      'This page explains design choices that can help reduce privacy risk.',
                    ],
                  ),

                  const SizedBox(height: 14),

                  _SectionCard(
                    title: 'Privacy-first by default',
                    icon: Icons.security_rounded,
                    iconColor: const Color(0xFF34C759),
                    primaryColor: primaryColor,
                    isDark: isDark,
                    bullets: const [
                      'Transcription is processed on-device (no transcript required to be sent to us).',
                      'Your transcripts are stored locally on your device unless you choose to export/share them.',
                      'You control what you share and where you share it.',
                    ],
                  ),

                  const SizedBox(height: 14),

                  _SectionCard(
                    title: 'Data minimization',
                    icon: Icons.filter_alt_outlined,
                    iconColor: primaryColor,
                    primaryColor: primaryColor,
                    isDark: isDark,
                    bullets: const [
                      'We store only account-related data needed to verify purchases.',
                      'You can delete transcripts (Trash keeps them temporarily for recovery).',
                      'Optional features (like auto-email) are user-controlled and can be turned off.',
                    ],
                  ),

                  const SizedBox(height: 14),

                  _SectionCard(
                    title: 'Security-minded workflow',
                    icon: Icons.lock_outline_rounded,
                    iconColor: const Color(0xFF5856D6),
                    primaryColor: primaryColor,
                    isDark: isDark,
                    bullets: const [
                      'If you export/share files, treat them as sensitive and store them in approved systems.',
                      'Use device lock + OS encryption and keep your phone updated.',
                      'Avoid sharing PHI in unsupported channels (public email inboxes, unsecured storage, etc.).',
                    ],
                  ),

                  const SizedBox(height: 14),

                  _SectionCard(
                    title: 'What we are NOT promising',
                    icon: Icons.cancel_outlined,
                    iconColor: const Color(0xFFFF3B30),
                    primaryColor: primaryColor,
                    isDark: isDark,
                    bullets: const [
                      'No “HIPAA certified” claims.',
                      'No guarantee of compliance for your organization.',
                      'No replacement for legal/compliance review.',
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HipaaInfoCard extends StatelessWidget {
  const _HipaaInfoCard({
    required this.primaryColor,
    required this.fg,
    required this.muted,
    required this.isDark,
  });

  final Color primaryColor;
  final Color fg;
  final Color muted;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: GlassTokens.cardColor(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: GlassTokens.borderColor(context), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.20 : 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: primaryColor.withValues(alpha: isDark ? 0.16 : 0.10),
            ),
            child: Icon(Icons.privacy_tip_outlined, color: primaryColor, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Designed to reduce risk',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: fg,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'We aim for a privacy-first architecture that can support HIPAA-conscious workflows when used appropriately.',
                  style: TextStyle(
                    color: muted,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _MetaPill(
                      text: 'On-device',
                      primaryColor: primaryColor,
                      isDark: isDark,
                    ),
                    _MetaPill(
                      text: 'Local storage',
                      primaryColor: primaryColor,
                      isDark: isDark,
                    ),
                    _MetaPill(
                      text: 'User-controlled export',
                      primaryColor: primaryColor,
                      isDark: isDark,
                    ),
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

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.bullets,
    required this.primaryColor,
    required this.isDark,
  });

  final String title;
  final IconData icon;
  final Color iconColor;
  final List<String> bullets;
  final Color primaryColor;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: GlassTokens.cardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: GlassTokens.borderColor(context), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: isDark ? 0.16 : 0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 16, color: iconColor),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final t in bullets) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: primaryColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t,
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: muted,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({
    required this.text,
    required this.primaryColor,
    required this.isDark,
  });

  final String text;
  final Color primaryColor;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
      decoration: BoxDecoration(
        color: primaryColor.withValues(alpha: isDark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: primaryColor,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          height: 1.0,
        ),
      ),
    );
  }
}
