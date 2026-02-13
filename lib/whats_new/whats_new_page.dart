// lib/whats_new/whats_new_page.dart
import 'package:flutter/material.dart';

class WhatsNewPage extends StatelessWidget {
  const WhatsNewPage({super.key});

  static const _appName = 'Meeting Transcript Unlimited';
  static const _version = '1.1.1';

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF0B0C10);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        title: const Text("What’s new"),
        leading: Padding(
          padding: const EdgeInsets.all(7.0),
          child: _IconPillButton(
            tooltip: 'Close',
            icon: Icons.arrow_back,
            onTap: () => Navigator.of(context).pop(),
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _HeaderCard(appName: _appName, version: _version),
              const SizedBox(height: 12),

              // ✅ Scrollable content (sections + numbered list)
              Expanded(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  children: [
                    const _SectionHeader(
                      title: 'New Features',
                      
                    ),
                    const SizedBox(height: 8),
                    _NumberedList(items: _newFeatures, isDark: isDark),

                    const SizedBox(height: 16),

                    const _SectionHeader(
                      title: 'Improvements',
                      
                    ),
                    const SizedBox(height: 8),
                    _NumberedList(items: _improvements, isDark: isDark),

                    const SizedBox(height: 16),

                    const _SectionHeader(
                      title: 'Fixes',
                    
                    ),
                    const SizedBox(height: 8),
                    _NumberedList(items: _fixes, isDark: isDark),

                    const SizedBox(height: 10),
                  ],
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
// ✅ 10 total items (for scrolling)
// ------------------------
const List<String> _newFeatures = [
  'Favourites tab to star important transcripts.',
  'Sort transcripts by date (newest/oldest).',
  'Sort transcripts by title (A→Z / Z→A).',
  'Trash system (3-day recovery) for deleted transcripts.',
];

const List<String> _improvements = [
  'Cleaner panels and spacing in Timeline and Settings.',
  'Faster list rendering for large transcript libraries.',
  'Better empty states and helpful microcopy.',
];

const List<String> _fixes = [
  'Fixed occasional UI flicker when returning from details.',
  'Improved stability during background transcription.',
  'Minor performance and crash fixes.',
];

// ------------------------
// UI widgets
// ------------------------
class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.appName, required this.version});

  final String appName;
  final String version;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final border = (isDark ? Colors.white : Colors.black).withOpacity(0.10);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF101018),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            color: Colors.black.withOpacity(0.25),
            offset: const Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: Colors.white.withOpacity(0.06),
              border: Border.all(color: Colors.white.withOpacity(0.10)),
            ),
            child: const Icon(Icons.new_releases_outlined),
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
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _Pill(
                      text: 'Version $version',
                      color: Colors.white,
                    ),
                    // const _Pill(text: 'Release notes'),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 1),
          
        ],
      ),
    );
  }
}

class _NumberedList extends StatelessWidget {
  const _NumberedList({required this.items, required this.isDark});

  final List<String> items;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final border = (isDark ? Colors.white : Colors.black).withOpacity(0.10);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF101018),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border),
      ),
      child: ListView.separated(
        itemCount: items.length,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(), // parent scrolls
        separatorBuilder: (_, __) => Divider(
          height: 1,
          thickness: 0.6,
          color: Colors.white.withOpacity(0.08),
        ),
        itemBuilder: (ctx, i) {
          final n = i + 1;
          return Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _IndexPill(symbol: '✦'),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    items[i],
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
        color: c.withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withOpacity(0.30)),
      ),
      child: Text(
        symbol,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w900,
          color: Colors.white24,
          height: 1.0,
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.white70;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withOpacity(0.25)),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: c),
      ),
    );
  }
}

class _IconPillButton extends StatelessWidget {
  const _IconPillButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final border = (isDark ? Colors.white : Colors.black).withOpacity(0.10);
    final bg = (isDark ? Colors.white : Colors.black).withOpacity(0.06);

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: bg,
          border: Border.all(color: border),
        ),
        child: Tooltip(
          message: tooltip,
          child: Icon(
            icon,
            color: onTap == null
                ? (isDark ? Colors.white38 : Colors.black38)
                : null,
          ),
        ),
      ),
    );
  }
}