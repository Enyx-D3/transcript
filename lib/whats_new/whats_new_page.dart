// lib/whats_new/whats_new_page.dart
import 'package:flutter/material.dart';
import 'package:transcript/widgets/icon_pill_button.dart';

// ✅ Glass primitives (same family as RecordSheet / TrashPage)
import '../ui/glass/glass_background.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';

class WhatsNewPage extends StatelessWidget {
  const WhatsNewPage({super.key});

  static const _appName = 'Meeting Transcript Unlimited';
  static const _version = '2.0.0';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final fg = GlassTokens.fg(context, alpha: 0.92);
    final muted = GlassTokens.muted(context, alpha: 0.70);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GlassBackground(
        child: SafeArea(
          child: Column(
            children: [
              // ✅ Header row (no AppBar)
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
                        "What’s new",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.2,
                          color: fg,
                        ),
                      ),
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
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _HeaderCard(
                        appName: _appName,
                        version: _version,
                        fg: fg,
                        muted: muted,
                      ),
                      const SizedBox(height: 12),

                      // ✅ One scroll view
                      Expanded(
                        child: ListView(
                          physics: const BouncingScrollPhysics(),
                          children: const [
                            _SectionHeader(title: 'New Features'),
                            SizedBox(height: 8),
                            _NumberedList(items: _newFeatures),

                            SizedBox(height: 16),

                            _SectionHeader(title: 'Improvements'),
                            SizedBox(height: 8),
                            _NumberedList(items: _improvements),

                            SizedBox(height: 16),

                            _SectionHeader(title: 'Fixes'),
                            SizedBox(height: 8),
                            _NumberedList(items: _fixes),

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

// ------------------------
// ✅ Data
// ------------------------
const List<String> _newFeatures = [
  'Auto-generate summary after transcription',
  'AI-powered typo correction',
  'Refined glass UI design',
];

const List<String> _improvements = [
  'Faster transcription and summary generation',
  'Optimized audio and video file processing',
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
    required this.fg,
    required this.muted,
  });

  final String appName;
  final String version;
  final Color fg;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      variant: GlassCardVariant.tile,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: Colors.white.withValues(alpha: 0.06),
              border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            ),
            child: Icon(Icons.new_releases_outlined, color: fg),
          ),
          const SizedBox(width: 12),
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
                    fontWeight: FontWeight.w900,
                    color: fg,
                    letterSpacing: -0.1,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _Pill(text: 'Version $version', color: Colors.white),
                    _Pill(text: 'Release notes', color: muted),
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
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context, alpha: 0.92);
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.2,
          color: fg,
        ),
      ),
    );
  }
}

class _NumberedList extends StatelessWidget {
  const _NumberedList({required this.items});
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final textColor = isDark ? Colors.white70 : Colors.black87;

    return GlassCard(
      variant: GlassCardVariant.tile,
      padding: EdgeInsets.zero,
      child: ListView.separated(
        itemCount: items.length,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        separatorBuilder: (_, _) =>
            const GlassDivider(height: 1, thickness: 0.8),
        itemBuilder: (ctx, i) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _IndexPill(symbol: '${i + 1}'),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    items[i],
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: textColor,
                      height: 1.25,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _IndexPill extends StatelessWidget {
  const _IndexPill({required this.symbol});
  final String symbol;

  @override
  Widget build(BuildContext context) {
    const c = Colors.white;
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withValues(alpha: 0.30)),
      ),
      child: Text(
        symbol,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w900,
          color: Colors.white70,
          height: 1.0,
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w900,
          color: color.withValues(alpha: 0.95),
          height: 1.0,
        ),
      ),
    );
  }
}