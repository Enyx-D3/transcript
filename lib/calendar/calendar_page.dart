// lib/calendar/calendar_page.dart
import 'dart:io';
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
    final firstNext =
        (m.month == 12) ? DateTime(m.year + 1, 1, 1) : DateTime(m.year, m.month + 1, 1);
    return firstNext; // exclusive upper bound
  }

  DateTime _truncateDate(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  void _loadMonth() {
    final obx = ObjectBox.I;

    final start = _startOfMonth(_monthAnchor);
    final end = _endOfMonthExclusive(_monthAnchor);

    // Query all ordered by createdAt, filter to this month in Dart
    final qb = obx.transcripts.query()
      ..order(TranscriptEntity_.createdAt); // ascending
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

  @override
  Widget build(BuildContext context) {
    final days = _buildMonthDays(_monthAnchor);
    final today = _truncateDate(DateTime.now());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: 'Previous month',
            icon: const Icon(Icons.chevron_left),
            onPressed: _prevMonth,
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                _monthLabel(_monthAnchor),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Next month',
            icon: const Icon(Icons.chevron_right),
            onPressed: _nextMonth,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          children: [
            const SizedBox(height: 8),
            _legendTwoColor(),
            const SizedBox(height: 8),
            _weekHeader(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: GridView.builder(
                  physics: const BouncingScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7, // Mon..Sun
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
                      count: count,                 // keep count visible
                      onTap: () => _openDaySheet(d),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Monday-first labels
  Widget _weekHeader() {
    const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: labels
            .map((t) => Expanded(
                  child: Text(
                    t,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      letterSpacing: 0.2,
                    ),
                  ),
                ))
            .toList(),
      ),
    );
  }

  // Two-color legend (no intensity scale)
  Widget _legendTwoColor() {
    Widget box(Color c, String label) => Row(
          children: [
            Container(
              width: 16,
              height: 16,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: c,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12)),
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
      'January','February','March','April','May','June',
      'July','August','September','October','November','December'
    ];
    return '${months[a.month - 1]} ${a.year}';
  }

  /// Build a 6-row calendar (42 cells), Monday-first.
  List<DateTime> _buildMonthDays(DateTime anchor) {
    final first = _startOfMonth(anchor);
    // weekday: Mon=1..Sun=7 → Monday-first offset:
    final leading = (first.weekday + 6) % 7; // 0..6; 0 if Mon
    final start = first.subtract(Duration(days: leading));

    // Always show 6 rows → 42 days
    return List.generate(42, (i) => start.add(Duration(days: i)));
  }

  Future<void> _openDaySheet(DateTime day) async {
    final obx = ObjectBox.I;
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));

    // Query all (ordered), then filter for that specific day.
    final qb = obx.transcripts.query()
      ..order(TranscriptEntity_.createdAt);
    final q = qb.build();
    final all = q.find();
    q.close();

    final items = all.where((t) {
      final local = t.createdAt.toLocal();
      return !local.isBefore(start) && local.isBefore(end);
    }).toList();

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xFF0B0C10),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
            child: items.isEmpty
                ? const SizedBox(
                    height: 120,
                    child: Center(
                      child: Text(
                        'No transcripts on this day.',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  )
                : ListView.separated(
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

                      // If you later add `audioPath` to TranscriptEntity, re-enable:
                      // final hasAudio = (t.audioPath != null &&
                      //     t.audioPath!.isNotEmpty &&
                      //     File(t.audioPath!).existsSync());

                      return ListTile(
                        leading: const Icon(Icons.description, color: Color(0xFFCD66FD)),
                        title: Text(title),
                        subtitle: Text('$hh:$mm • ${_fmtDuration(t.durationSec)}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).pop(); // close sheet
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => TranscriptDetailPage(transcriptId: t.id),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        );
      },
    );
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

  const _DayCell({
    required this.date,
    required this.inMonth,
    required this.isToday,
    required this.hasTranscripts,
    required this.count,
    required this.onTap,
    super.key,
  });

  // Two fixed colors
  static const neutralColor = Color.fromARGB(255, 28, 30, 43); //0xFF12131A
  static const highlightColor = Color(0xFF463458);
  static const todayBorder = Color(0xFF0CD8D8);

  @override
  Widget build(BuildContext context) {
    final dayNum = date.day.toString();

    return Material(
      color: hasTranscripts ? highlightColor : neutralColor,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: isToday
                ? Border.all(color: todayBorder.withValues(alpha: 0.9), width: 1.3)
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
                    fontWeight: FontWeight.w600,
                    color: inMonth ? Colors.white : Colors.white38,
                  ),
                ),
              ),
              if (count > 0)
                Align(
                  alignment: Alignment.bottomRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
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
