// lib/calendar/calendar_page.dart
import 'package:flutter/material.dart';
import 'package:objectbox/objectbox.dart';

import '../objectbox/objectbox_store.dart';
import '../transcript/transcript_detail_page.dart';
import '../objectbox.g.dart';

/// Month-view calendar: two colors only
/// - Days with transcripts use a highlight color
/// - Days without transcripts use a neutral color
/// - Shows count on each day (bottom-right)
/// - Tap a day to open a bottom sheet with that day's transcripts
/// - Today has a neon border
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
    final qb = obx.transcripts.query(TranscriptEntity_.isDeleted.equals(false))..order(TranscriptEntity_.createdAt);
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

    setState(() {
      _countByDate = map;
    });
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

  BoxDecoration _panelDecoration(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = isDark ? const Color(0xFF101018) : theme.colorScheme.surface;
    final border = isDark
        ? Colors.white.withOpacity(0.10)
        : Colors.black.withOpacity(0.08);

    return BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: border),
      boxShadow: [
        BoxShadow(
          blurRadius: 18,
          color: Colors.black.withOpacity(isDark ? 0.25 : 0.08),
          offset: const Offset(0, 10),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final days = _buildMonthDays(_monthAnchor);
    final today = _truncateDate(DateTime.now());

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      // ✅ No default AppBar: custom header for uniqueness
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
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Tap to view transcripts',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: isDark ? Colors.white70 : Colors.black54,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),

                  _IconPillButton(
                    tooltip: 'Previous month',
                    icon: Icons.chevron_left,
                    onTap: _prevMonth,
                  ),
                  const SizedBox(width: 6),

                  // ✅ Flexible month pill so it never overflows
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: (isDark ? Colors.white : Colors.black)
                            .withOpacity(0.06),
                        border: Border.all(
                          color: (isDark ? Colors.white : Colors.black)
                              .withOpacity(0.10),
                        ),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.center,
                        child: Text(
                          _monthLabel(_monthAnchor),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(width: 6),
                  _IconPillButton(
                    tooltip: 'Next month',
                    icon: Icons.chevron_right,
                    onTap: _nextMonth,
                  ),
                ],
              ),

              const SizedBox(height: 14),

              // Legend + week header inside a panel
              Container(
                decoration: _panelDecoration(context),
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

              // Calendar grid inside a panel
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12), // 👈 adjust as needed
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
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  letterSpacing: 0.2,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  // Two-color legend (no intensity scale)
  Widget _legendTwoColor() {
    Widget box(Color c, String label) => Row(
      children: [
        Container(
          width: 14,
          height: 14,
          margin: const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(
            color: c,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 12),
        ),
      ],
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        box(_DayCell.neutralColor, 'No transcript'),
        const SizedBox(width: 16),
        box(_DayCell.highlightColor, 'Has transcripts'),
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
      backgroundColor: const Color(0xFF0B0C10),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Sheet header
                Row(
                  children: [
                    const Icon(Icons.calendar_month, color:Colors.white),
                    const SizedBox(width: 10),
                    Text(
                      '${day.day.toString().padLeft(2, '0')} ${_monthLabel(DateTime(day.year, day.month, 1)).split(' ')[0]}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: Colors.white.withOpacity(0.06),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.10),
                        ),
                      ),
                      child: Text(
                        '${items.length} item${items.length == 1 ? '' : 's'}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
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
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final t = items[i];
                        final when = t.createdAt.toLocal();
                        final hh = when.hour.toString().padLeft(2, '0');
                        final mm = when.minute.toString().padLeft(2, '0');
                        final title = (t.title?.trim().isNotEmpty ?? false)
                            ? t.title!.trim()
                            : 'Untitled';

                        return ListTile(
                          leading: const _LeadingPillIcon(
                            icon: Icons.description,
                          ),
                          title: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '$hh:$mm • ${_fmtDuration(t.durationSec)}',
                          ),
                          trailing: const Icon(Icons.chevron_right),
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

class _IconPillButton extends StatelessWidget {
  const _IconPillButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: (isDark ? Colors.white : Colors.black).withOpacity(0.06),
          border: Border.all(
            color: (isDark ? Colors.white : Colors.black).withOpacity(0.10),
          ),
        ),
        child: Tooltip(message: tooltip, child: Icon(icon)),
      ),
    );
  }
}

class _LeadingPillIcon extends StatelessWidget {
  const _LeadingPillIcon({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final border = isDark
        ? Colors.white.withOpacity(0.12)
        : Colors.black.withOpacity(0.08);
    final bg = isDark
        ? Colors.white.withOpacity(0.06)
        : Colors.black.withOpacity(0.04);

    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: Icon(icon, size: 20, color: Colors.white),
    );
  }
}

class _DayCell extends StatelessWidget {
  final DateTime date;
  final bool inMonth;
  final bool isToday;
  final bool hasTranscripts;
  final int count;
  final VoidCallback onTap;

  const _DayCell({
    required this.date,
    required this.inMonth,
    required this.isToday,
    required this.hasTranscripts,
    required this.count,
    required this.onTap,
    super.key,
  });

  static const neutralColor = Color.fromARGB(255, 28, 30, 43);
  static const highlightColor = Colors.white30;
  static const todayBorder = Colors.white;

  @override
  Widget build(BuildContext context) {
    final dayNum = date.day.toString();

    return Material(
      color: hasTranscripts ? highlightColor : neutralColor,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: isToday
                ? Border.all(color: todayBorder.withOpacity(0.90), width: 1.4)
                : null,
          ),
          child: Stack(
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: Text(
                  dayNum,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: inMonth ? Colors.white : Colors.white38,
                  ),
                ),
              ),
              if (count > 0)
                Align(
                  alignment: Alignment.bottomRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.25),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white.withOpacity(0.08)),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
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
  }
}
