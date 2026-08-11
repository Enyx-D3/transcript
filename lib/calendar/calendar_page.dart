// lib/calendar/calendar_page.dart
import 'package:flutter/material.dart';
import 'package:transcript/widgets/icon_pill_button.dart';
import 'package:transcript/widgets/leading_pill_icon.dart';

import '../objectbox/objectbox_store.dart';
import '../transcript/transcript_detail_page.dart';
import '../objectbox.g.dart';

// ✅ Glass primitives
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';

/// Month-view calendar (Apple glass)
/// PERF VERSION:
/// - NO per-cell blur (global background blur recommended)
/// - Cells are tint+border only (fast)
class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late DateTime _monthAnchor; // first day of current month (local)
  Map<DateTime, int> _countByDate = const {};

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _monthAnchor = DateTime(now.year, now.month, 1);
    _loadMonth();
  }

  // ---------- Data ----------

  DateTime _startOfMonth(DateTime m) => DateTime(m.year, m.month, 1);

  DateTime _endOfMonthExclusive(DateTime m) {
    final firstNext = (m.month == 12)
        ? DateTime(m.year + 1, 1, 1)
        : DateTime(m.year, m.month + 1, 1);
    return firstNext; // exclusive upper bound
  }

  DateTime _truncateDate(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  void _loadMonth() {
    final obx = ObjectBox.I;

    final start = _startOfMonth(_monthAnchor);
    final end = _endOfMonthExclusive(_monthAnchor);

    // Query all ordered by createdAt, filter to this month in Dart
    final qb = obx.transcripts.query(TranscriptEntity_.isDeleted.equals(false))
      ..order(TranscriptEntity_.createdAt);
    final q = qb.build();
    final all = q.find();
    q.close();

    final inMonth = all.where((t) {
      final local = t.createdAt.toLocal();
      return !local.isBefore(start) && local.isBefore(end);
    }).toList();

    final map = <DateTime, int>{};
    for (final t in inMonth) {
      final d = _truncateDate(t.createdAt.toLocal());
      map[d] = (map[d] ?? 0) + 1;
    }

    setState(() => _countByDate = map);
  }

  // ---------- UI ----------

  void _prevMonth() {
    final m = _monthAnchor.month == 1
        ? DateTime(_monthAnchor.year - 1, 12, 1)
        : DateTime(_monthAnchor.year, _monthAnchor.month - 1, 1);
    setState(() => _monthAnchor = m);
    _loadMonth();
  }

  void _nextMonth() {
    final m = _monthAnchor.month == 12
        ? DateTime(_monthAnchor.year + 1, 1, 1)
        : DateTime(_monthAnchor.year, _monthAnchor.month + 1, 1);
    setState(() => _monthAnchor = m);
    _loadMonth();
  }

  @override
  Widget build(BuildContext context) {
    final days = _buildMonthDays(_monthAnchor);
    final today = _truncateDate(DateTime.now());

    final isDark = GlassTokens.isDark(context);

    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---------- Header ----------
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Calendar',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                                color: fg,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Tap to view transcripts',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: muted,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),

                  IconPillButton(
                    tooltip: 'Previous month',
                    icon: Icons.chevron_left,
                    onTap: _prevMonth,
                  ),
                  const SizedBox(width: 6),

                  // Month pill
                  Flexible(
                    child: LiquidGlass(
                      borderRadius: BorderRadius.circular(999),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 9,
                      ),
                      backgroundColor: isDark
                          ? GlassTokens.surfaceDark
                          : GlassTokens.surfaceLight,
                      shadow: false,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.center,
                        child: Text(
                          _monthLabel(_monthAnchor),
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: fg,
                            letterSpacing: 0.1,
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(width: 6),
                  IconPillButton(
                    tooltip: 'Next month',
                    icon: Icons.chevron_right,
                    onTap: _nextMonth,
                  ),
                ],
              ),

              const SizedBox(height: 14),

              // Legend + week header inside a glass panel
              GlassCard(
                variant: GlassCardVariant.tile,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  children: [
                    _legendTwoColor(),
                    const SizedBox(height: 10),
                    _weekHeader(),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // Calendar grid (tint-only day cells)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: GridView.builder(
                    physics: const BouncingScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 7,
                          crossAxisSpacing: 6,
                          mainAxisSpacing: 6,
                        ),
                    itemCount: days.length,
                    itemBuilder: (ctx, i) {
                      final d = days[i];
                      final inMonth = d.month == _monthAnchor.month;
                      final isToday = _truncateDate(d) == today;

                      final key = _truncateDate(d);
                      final count = _countByDate[key] ?? 0;
                      final hasTranscripts = count > 0;

                      return _DayCell(
                        date: d,
                        inMonth: inMonth,
                        isToday: isToday,
                        hasTranscripts: hasTranscripts,
                        count: count,
                        onTap: () => _openDaySheet(d),
                        isDark: isDark,
                      );
                    },
                  ),
                ),
              ),

              const SizedBox(height: 72), // space for bottom dock nav
            ],
          ),
        ),
      ),
    );
  }

  // Monday-first labels
  Widget _weekHeader() {
    final muted = GlassTokens.muted(context);
    const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return Row(
      children: labels
          .map(
            (t) => Expanded(
              child: Text(
                t,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: muted,
                  fontSize: 12,
                  letterSpacing: 0.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  // Two-color legend (no intensity scale)
  Widget _legendTwoColor() {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    Widget box({
      required Color bg,
      required Color border,
      bool showDot = false,
    }) {
      return Container(
        width: 18,
        height: 18,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: bg,
          border: Border.all(
            color: border,
            width: 1,
          ),
        ),
        child: showDot
            ? Center(
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: fg,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              )
            : null,
      );
    }

    Widget item({
      required Color bg,
      required Color border,
      required String label,
      required bool showDot,
    }) {
      return Row(
        children: [
          box(bg: bg, border: border, showDot: showDot),
          Text(
            label,
            style: TextStyle(
              color: muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    final noBg = isDark ? GlassTokens.surfaceDark : GlassTokens.surfaceLight;
    final noBorder = isDark ? GlassTokens.borderDark : GlassTokens.borderLight;
    final hasBg = isDark ? const Color(0xFF282832) : const Color(0xFFE2E2EA);
    final hasBorder = isDark ? const Color(0xFF383844) : const Color(0xFFCCCCD8);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        item(bg: noBg, border: noBorder, label: 'No transcript', showDot: false),
        const SizedBox(width: 16),
        item(
          bg: hasBg,
          border: hasBorder,
          label: 'Has transcripts',
          showDot: true,
        ),
      ],
    );
  }

  String _monthLabel(DateTime a) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${months[a.month - 1]} ${a.year}';
  }

  /// Build a 6-row calendar (42 cells), Monday-first.
  List<DateTime> _buildMonthDays(DateTime anchor) {
    final first = _startOfMonth(anchor);
    final leading = (first.weekday + 6) % 7; // 0..6; 0 if Mon
    final start = first.subtract(Duration(days: leading));
    return List.generate(42, (i) => start.add(Duration(days: i)));
  }

  Future<void> _openDaySheet(DateTime day) async {
    void unfocus() => FocusManager.instance.primaryFocus?.unfocus();
    unfocus();

    final obx = ObjectBox.I;
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));

    final qb = obx.transcripts.query()..order(TranscriptEntity_.createdAt);
    final q = qb.build();
    final all = q.find();
    q.close();

    final items = all.where((t) {
      final local = t.createdAt.toLocal();
      return !local.isBefore(start) && local.isBefore(end);
    }).toList();

    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final fg = GlassTokens.fg(ctx);
        final muted = GlassTokens.muted(ctx);
        final isDark = GlassTokens.isDark(ctx);

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
            child: GlassCard(
              variant: GlassCardVariant.panel,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Sheet header
                  Row(
                    children: [
                      Icon(
                        Icons.calendar_month,
                        color: fg,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '${day.day.toString().padLeft(2, '0')} ${_monthLabel(DateTime(day.year, day.month, 1)).split(' ')[0]}',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          color: fg,
                        ),
                      ),
                      const Spacer(),

                      // Count pill
                      LiquidGlass(
                        borderRadius: BorderRadius.circular(999),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        backgroundColor: isDark
                            ? GlassTokens.surfaceDark
                            : GlassTokens.surfaceLight,
                        shadow: false,
                        child: Text(
                          '${items.length} item${items.length == 1 ? '' : 's'}',
                          style: TextStyle(
                            color: muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  if (items.isEmpty)
                    SizedBox(
                      height: 120,
                      child: Center(
                        child: Text(
                          'No transcripts on this day.',
                          style: TextStyle(
                            color: muted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: items.length,
                        addRepaintBoundaries: false,
                        addAutomaticKeepAlives: false,
                        separatorBuilder: (_, _) => const GlassDivider(),
                        itemBuilder: (_, i) {
                          final t = items[i];
                          final when = t.createdAt.toLocal();
                          final hh = when.hour.toString().padLeft(2, '0');
                          final mm = when.minute.toString().padLeft(2, '0');
                          final title = (t.title?.trim().isNotEmpty ?? false)
                              ? t.title!.trim()
                              : 'Untitled';

                          return ListTile(
                            leading: const LeadingPillIcon(
                              icon: Icons.description,
                            ),
                            title: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: fg,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              '$hh:$mm • ${_fmtDuration(t.durationSec)}',
                              style: TextStyle(
                                color: muted,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            trailing: Icon(
                              Icons.chevron_right,
                              color: muted,
                            ),
                            onTap: () {
                              unfocus();
                              Navigator.of(context).pop();
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      TranscriptDetailPage(transcriptId: t.id),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );

    unfocus();
  }

  String _fmtDuration(double sec) {
    final s = sec.isFinite && sec >= 0 ? sec : 0.0;
    final total = s.round();
    final m = (total ~/ 60).toString();
    final ss = (total % 60).toString().padLeft(2, '0');
    return '${m}m${ss}s';
  }
}

class _DayCell extends StatelessWidget {
  final DateTime date;
  final bool inMonth;
  final bool isToday;
  final bool hasTranscripts;
  final int count;
  final VoidCallback onTap;
  final bool isDark;

  const _DayCell({
    required this.date,
    required this.inMonth,
    required this.isToday,
    required this.hasTranscripts,
    required this.count,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final dayNum = date.day.toString();
    final fg = GlassTokens.fg(context);

    final bg = hasTranscripts
        ? (isDark ? const Color(0xFF282832) : const Color(0xFFE2E2EA))
        : (isDark ? GlassTokens.surfaceDark : GlassTokens.surfaceLight);

    final borderColor = isToday
        ? (isDark ? Colors.white : Colors.black)
        : (isDark ? GlassTokens.borderDark : GlassTokens.borderLight);

    const r = 10.0;
    final outerRadius = BorderRadius.circular(r);

    return InkWell(
      borderRadius: outerRadius,
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: outerRadius,
          color: bg,
          border: Border.all(
            color: borderColor,
            width: isToday ? 1.5 : 1.0,
          ),
        ),
        padding: const EdgeInsets.all(6),
        child: Stack(
          children: [
            // Day number
            Align(
              alignment: Alignment.topLeft,
              child: Text(
                dayNum,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: hasTranscripts
                      ? FontWeight.w800
                      : FontWeight.w600,
                  color: inMonth
                      ? fg
                      : fg.withValues(alpha: 0.35),
                ),
              ),
            ),

            // Dot indicator
            if (hasTranscripts)
              Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 2, bottom: 2),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: fg,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
              ),

            // Count badge
            if (count > 0)
              Align(
                alignment: Alignment.bottomRight,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    color: isDark
                        ? const Color(0xFF383844)
                        : const Color(0xFFCCCCD8),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: fg,
                      letterSpacing: 0.2,
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
