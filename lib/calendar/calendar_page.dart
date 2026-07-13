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
                                color: Colors.white.withValues(alpha: 0.92),
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Tap to view transcripts',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Colors.white.withValues(alpha: 0.70),
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

                  // Month pill (NO blur)
                  Flexible(
                    child: LiquidGlass(
                      borderRadius: BorderRadius.circular(999),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 9,
                      ),
                      shadow: false,

                      // ✅ PERF: no blur/grain for small controls
                      blurX: 0,
                      blurY: 0,
                      grain: false,

                      tintOpacityDark: 0.060,
                      tintOpacityLight: 0.050,
                      borderOpacityDark: 0.14,
                      borderOpacityLight: 0.18,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.center,
                        child: Text(
                          _monthLabel(_monthAnchor),
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Colors.white.withValues(alpha: 0.92),
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
    const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return Row(
      children: labels
          .map(
            (t) => Expanded(
              child: Text(
                t,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.70),
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
    Widget box({
      required double tint,
      required double borderA,
      bool showDot = false,
    }) {
      return Container(
        width: 18,
        height: 18,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: Colors.white.withValues(alpha: tint),
          border: Border.all(
            color: Colors.white.withValues(alpha: borderA),
            width: 1,
          ),
        ),
        child: showDot
            ? Center(
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              )
            : null,
      );
    }

    Widget item({
      required double tint,
      required double borderA,
      required String label,
      required bool showDot,
    }) {
      return Row(
        children: [
          box(tint: tint, borderA: borderA, showDot: showDot),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.60),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    // Match your day-cell tuning:
    // No transcript: tint 0.08, border 0.12
    // Has transcripts: tint 0.20, border 0.26 (and dot)
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        item(tint: 0.08, borderA: 0.12, label: 'No transcript', showDot: false),
        const SizedBox(width: 16),
        item(
          tint: 0.20,
          borderA: 0.26,
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
                        color: Colors.white.withValues(alpha: 0.88),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '${day.day.toString().padLeft(2, '0')} ${_monthLabel(DateTime(day.year, day.month, 1)).split(' ')[0]}',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          color: Colors.white.withValues(alpha: 0.92),
                        ),
                      ),
                      const Spacer(),

                      // Count pill (NO blur)
                      LiquidGlass(
                        borderRadius: BorderRadius.circular(999),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        shadow: false,
                        blurX: 0,
                        blurY: 0,
                        grain: false,
                        tintOpacityDark: 0.060,
                        tintOpacityLight: 0.050,
                        borderOpacityDark: 0.14,
                        borderOpacityLight: 0.18,
                        child: Text(
                          '${items.length} item${items.length == 1 ? '' : 's'}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.70),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  if (items.isEmpty)
                    const SizedBox(
                      height: 120,
                      child: Center(
                        child: Text(
                          'No transcripts on this day.',
                          style: TextStyle(
                            color: Colors.white70,
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

                        // ✅ PERF: keep compositing stable
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

                          return Material(
                            color: Colors.transparent,
                            child: ListTile(
                              leading: const LeadingPillIcon(
                                icon: Icons.description,
                              ),
                              title: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.92),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                '$hh:$mm • ${_fmtDuration(t.durationSec)}',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.70),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              trailing: Icon(
                                Icons.chevron_right,
                                color: Colors.white.withValues(alpha: 0.72),
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
                            ),
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

    // ✅ Make transcript-days visibly “filled”
    final baseTint = inMonth ? 1.0 : 0.45;
    final tint = (hasTranscripts ? 0.20 : 0.08) * baseTint;

    // ✅ Stronger border when transcripts exist
    final borderA = hasTranscripts ? 0.26 : 0.12;

    const borderW = 1.2; // today outline thickness
    const r = 10.0;

    final outerRadius = BorderRadius.circular(r);
    final innerRadius = BorderRadius.circular(r - borderW);

    final glassCell = InkWell(
      borderRadius: outerRadius,
      onTap: onTap,
      child: Padding(
        padding: isToday ? const EdgeInsets.all(borderW) : EdgeInsets.zero,
        child: LiquidGlass(
          borderRadius: isToday ? innerRadius : outerRadius,
          padding: const EdgeInsets.all(6),
          shadow: false,

          // ✅ PERF: NO blur/grain per cell
          blurX: 0,
          blurY: 0,
          grain: false,

          tintOpacityDark: tint,
          tintOpacityLight: tint * 0.80,
          borderOpacityDark: borderA,
          borderOpacityLight: borderA + 0.02,

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
                        ? Colors.white.withValues(alpha: 0.92)
                        : Colors.white.withValues(alpha: 0.35),
                  ),
                ),
              ),

              // ✅ Dot indicator (Apple-ish)
              if (hasTranscripts)
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 2, bottom: 2),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                ),

              // Count badge (kept)
              if (count > 0)
                Align(
                  alignment: Alignment.bottomRight,
                  child: LiquidGlass(
                    borderRadius: BorderRadius.circular(8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    shadow: false,
                    blurX: 0,
                    blurY: 0,
                    grain: false,

                    tintOpacityDark: 0.10,
                    tintOpacityLight: 0.08,
                    borderOpacityDark: 0.14,
                    borderOpacityLight: 0.16,
                    child: Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.white.withValues(alpha: 0.92),
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    if (!isToday) return glassCell;

    // Today outline
    return Container(
      decoration: BoxDecoration(
        borderRadius: outerRadius,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.70),
          width: borderW,
        ),
      ),
      child: glassCell,
    );
  }
}
