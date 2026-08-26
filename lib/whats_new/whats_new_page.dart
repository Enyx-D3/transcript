import 'package:flutter/material.dart';
import '../ui/glass/glass_tokens.dart';
import '../widgets/icon_pill_button.dart';

class WhatsNewPage extends StatelessWidget {
  const WhatsNewPage({super.key});

  static const _appName = 'Meeting Transcript Unlimited';
  static const _version = '2.0.1';

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
            // Header row with IconPillButton
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
                      "What's new",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        color: fg,
                      ),
                    ),
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
                  // App Version Header Card
                  _HeaderCard(
                    appName: _appName,
                    version: _version,
                    primaryColor: primaryColor,
                    fg: fg,
                    muted: muted,
                    isDark: isDark,
                  ),

                  const SizedBox(height: 20),

                  _SectionHeader(title: 'New Features', primaryColor: primaryColor),
                  const SizedBox(height: 10),
                  _NumberedListCard(items: _newFeatures, primaryColor: primaryColor, isDark: isDark),

                  const SizedBox(height: 20),

                  _SectionHeader(title: 'Improvements', primaryColor: primaryColor),
                  const SizedBox(height: 10),
                  _NumberedListCard(items: _improvements, primaryColor: primaryColor, isDark: isDark),

                  const SizedBox(height: 20),

                  _SectionHeader(title: 'Fixes & Stability', primaryColor: primaryColor),
                  const SizedBox(height: 10),
                  _NumberedListCard(items: _fixes, primaryColor: primaryColor, isDark: isDark),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------
// Data
// ------------------------
const List<String> _newFeatures = [
  'Auto-generate summary after transcription',
  'AI-powered typo correction',
  'Crimson & Dark modern theme variants',
];

const List<String> _improvements = [
  'Optimized audio and video file processing',
  'High-contrast solid interface redesign',
];

const List<String> _fixes = [
  'Improved background transcription stability',
  'Minor performance improvements and bug fixes',
];

// ------------------------
// UI widgets
// ------------------------
class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.appName,
    required this.version,
    required this.primaryColor,
    required this.fg,
    required this.muted,
    required this.isDark,
  });

  final String appName;
  final String version;
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
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: primaryColor.withValues(alpha: isDark ? 0.16 : 0.10),
            ),
            child: Icon(Icons.auto_awesome_rounded, color: primaryColor, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  appName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: fg,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _Pill(
                      text: 'v$version',
                      bgColor: primaryColor.withValues(alpha: isDark ? 0.18 : 0.12),
                      textColor: primaryColor,
                    ),
                    const SizedBox(width: 8),
                    _Pill(
                      text: 'Release notes',
                      bgColor: isDark ? const Color(0xFF242432) : const Color(0xFFEEEEF4),
                      textColor: muted,
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.primaryColor});
  final String title;
  final Color primaryColor;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context);
    return Row(
      children: [
        Container(
          width: 4,
          height: 14,
          decoration: BoxDecoration(
            color: primaryColor,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.1,
            color: fg,
          ),
        ),
      ],
    );
  }
}

class _NumberedListCard extends StatelessWidget {
  const _NumberedListCard({
    required this.items,
    required this.primaryColor,
    required this.isDark,
  });

  final List<String> items;
  final Color primaryColor;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context);

    return Container(
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
        children: List.generate(items.length, (i) {
          final isLast = i == items.length - 1;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 26,
                      height: 26,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: isDark ? 0.16 : 0.10),
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: primaryColor,
                          height: 1.0,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        items[i],
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                          color: fg,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (!isLast)
                Divider(
                  height: 1,
                  thickness: 1,
                  color: GlassTokens.borderColor(context),
                ),
            ],
          );
        }),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.text,
    required this.bgColor,
    required this.textColor,
  });

  final String text;
  final Color bgColor;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: textColor,
          height: 1.0,
        ),
      ),
    );
  }
}
