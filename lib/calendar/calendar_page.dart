// lib/calendar/calendar_page.dart
import 'dart:async';
import 'package:flutter/material.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../transcript/transcript_detail_page.dart';
import '../transcript/youtube_saved_detail_page.dart';
import '../objectbox.g.dart';

// ✅ Glass primitives
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_tokens.dart';
import '../widgets/icon_pill_button.dart';

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  // Base date for week index math (Monday)
  static final DateTime _baseDate = DateTime(2022, 1, 3);

  late DateTime _selectedDay;
  late int _currentWeekIndex;
  late PageController _pageController;

  // Cache: date -> transcripts list
  Map<DateTime, List<TranscriptEntity>> _transcriptsByDate = const {};

  DateTime _truncateDate(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  DateTime _startOfWeek(DateTime dt) {
    final truncated = _truncateDate(dt);
    final diff = (truncated.weekday - 1);
    return truncated.subtract(Duration(days: diff));
  }

  int _weekIndexForDate(DateTime dt) {
    final mon = _startOfWeek(dt);
    return mon.difference(_baseDate).inDays ~/ 7;
  }

  DateTime _dateForWeekIndex(int index) {
    return _baseDate.add(Duration(days: index * 7));
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDay = _truncateDate(now);
    _currentWeekIndex = _weekIndexForDate(now);
    _pageController = PageController(initialPage: _currentWeekIndex);

    _loadTranscripts();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadTranscripts() async {
    if (!mounted) return;

    try {
      final obx = ObjectBox.I;
      final qb = obx.transcripts.query(TranscriptEntity_.isDeleted.equals(false))
        ..order(TranscriptEntity_.createdAt, flags: Order.descending);
      final q = qb.build();
      final all = q.find();
      q.close();

      final map = <DateTime, List<TranscriptEntity>>{};
      for (final t in all) {
        final d = _truncateDate(t.createdAt.toLocal());
        map.putIfAbsent(d, () => []).add(t);
      }

      if (!mounted) return;
      setState(() {
        _transcriptsByDate = map;
      });
    } catch (_) {}
  }

  // ---------- Navigation Helpers ----------

  void _onWeekPageChanged(int index) {
    setState(() {
      _currentWeekIndex = index;
      final weekStart = _dateForWeekIndex(index);
      final weekEnd = weekStart.add(const Duration(days: 6));

      // If currently selected day is not in the new week, select the same weekday in new week
      if (_selectedDay.isBefore(weekStart) || _selectedDay.isAfter(weekEnd)) {
        final targetWeekday = _selectedDay.weekday;
        _selectedDay = weekStart.add(Duration(days: targetWeekday - 1));
      }
    });
  }

  void _goToPrevWeek() {
    _pageController.previousPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _goToNextWeek() {
    _pageController.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _jumpToToday() {
    final now = DateTime.now();
    final today = _truncateDate(now);
    final targetIndex = _weekIndexForDate(now);

    setState(() {
      _selectedDay = today;
      _currentWeekIndex = targetIndex;
    });

    if (_pageController.hasClients && _pageController.page?.round() != targetIndex) {
      _pageController.animateToPage(
        targetIndex,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _selectDay(DateTime day) {
    setState(() {
      _selectedDay = _truncateDate(day);
    });
  }

  Future<void> _openTranscript(TranscriptEntity t) async {
    final isYoutube = (t.sourceType) == 1;
    if (isYoutube) {
      final metaId = t.youtubeMetaId;
      if (metaId != null) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => YoutubeSavedTranscriptPage(
              transcriptId: t.id,
              youtubeMetaId: metaId,
            ),
          ),
        );
      } else {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TranscriptDetailPage(transcriptId: t.id),
          ),
        );
      }
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TranscriptDetailPage(transcriptId: t.id),
        ),
      );
    }
    await _loadTranscripts();
  }

  // ---------- Date Formatting ----------

  String _monthYearLabel(DateTime dt) {
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
    return '${months[dt.month - 1]} ${dt.year}';
  }

  String _formatSelectedDayHeader(DateTime d) {
    final today = _truncateDate(DateTime.now());
    final isToday = _truncateDate(d) == today;
    final yesterday = today.subtract(const Duration(days: 1));
    final isYesterday = _truncateDate(d) == yesterday;
    final tomorrow = today.add(const Duration(days: 1));
    final isTomorrow = _truncateDate(d) == tomorrow;

    const weekdayNames = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday'
    ];
    const monthNames = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];

    final prefix = isToday
        ? 'Today'
        : (isYesterday
            ? 'Yesterday'
            : (isTomorrow ? 'Tomorrow' : weekdayNames[d.weekday - 1]));

    return '$prefix • ${monthNames[d.month - 1]} ${d.day}';
  }

  String _fmtDurationShort(double sec) {
    final total = sec.isFinite && sec >= 0 ? sec.round() : 0;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;

    if (h > 0) {
      return '${h}h ${m}m';
    } else if (m > 0) {
      return '${m}m ${s}s';
    } else {
      return '${s}s';
    }
  }

  String _fmtTime(DateTime dt) {
    final h = dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    final period = h >= 12 ? 'PM' : 'AM';
    final formattedH = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    return '$formattedH:$m $period';
  }

  // ---------- Quick Month Picker Dialog ----------

  Future<void> _showMonthPickerSheet() async {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);

    int pickedYear = _selectedDay.year;
    int pickedMonth = _selectedDay.month;

    const monthNames = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];

    await showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF16161E) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header with Year switch
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.chevron_left_rounded),
                          color: fg,
                          onPressed: () => setSheetState(() => pickedYear--),
                        ),
                        Text(
                          '$pickedYear',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: fg,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.chevron_right_rounded),
                          color: fg,
                          onPressed: () => setSheetState(() => pickedYear++),
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),

                    // Months Grid (4x3)
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        childAspectRatio: 1.8,
                      ),
                      itemCount: 12,
                      itemBuilder: (context, i) {
                        final m = i + 1;
                        final isSelected = m == pickedMonth && pickedYear == _selectedDay.year;

                        return InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            Navigator.pop(ctx);
                            final targetDate = DateTime(pickedYear, m, 1);
                            final targetIndex = _weekIndexForDate(targetDate);
                            setState(() {
                              _selectedDay = targetDate;
                              _currentWeekIndex = targetIndex;
                            });
                            _pageController.jumpToPage(targetIndex);
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFF007AFF)
                                  : (isDark
                                      ? GlassTokens.surfaceDark
                                      : GlassTokens.surfaceLight),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              monthNames[i],
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                                color: isSelected ? Colors.white : fg,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ---------- Main Build ----------

  @override
  Widget build(BuildContext context) {
    final today = _truncateDate(DateTime.now());
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);
    final isSelectedToday = _selectedDay == today;

    final selectedDayTranscripts = _transcriptsByDate[_selectedDay] ?? const [];

    // Total duration of selected day
    double dayTotalSec = 0;
    for (final t in selectedDayTranscripts) {
      if (t.durationSec.isFinite && t.durationSec > 0) dayTotalSec += t.durationSec;
    }

    return Scaffold(
      backgroundColor: GlassTokens.backgroundColor(context),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Pinned Top Bar (Month selector & week navigation)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Month & Year Selector
                  InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: _showMonthPickerSheet,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _monthYearLabel(_selectedDay),
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.3,
                              color: fg,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 20,
                            color: muted,
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Navigation Actions (< > and Today)
                  Row(
                    children: [
                      IconPillButton(
                        tooltip: 'Previous week',
                        icon: Icons.chevron_left_rounded,
                        onTap: _goToPrevWeek,
                      ),
                      const SizedBox(width: 6),
                      IconPillButton(
                        tooltip: 'Next week',
                        icon: Icons.chevron_right_rounded,
                        onTap: _goToNextWeek,
                      ),
                      const SizedBox(width: 8),

                      // Jump to Today Pill
                      LiquidGlass(
                        borderRadius: BorderRadius.circular(999),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        backgroundColor: isSelectedToday
                            ? (isDark ? const Color(0xFF1E2A3A) : const Color(0xFFEBF3FF))
                            : (isDark ? GlassTokens.surfaceDark : GlassTokens.surfaceLight),
                        shadow: false,
                        onTap: _jumpToToday,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isSelectedToday ? const Color(0xFF007AFF) : muted,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Today',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: isSelectedToday ? FontWeight.w800 : FontWeight.w600,
                                color: isSelectedToday ? const Color(0xFF007AFF) : fg,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // 2. Pinned Horizontal Week Scroller Strip with Silky Bouncing Physics
            SizedBox(
              height: 84,
              child: PageView.builder(
                controller: _pageController,
                physics: const BouncingScrollPhysics(parent: PageScrollPhysics()),
                onPageChanged: _onWeekPageChanged,
                itemBuilder: (context, pageIndex) {
                  final monday = _dateForWeekIndex(pageIndex);
                  final weekDays = List.generate(7, (i) => monday.add(Duration(days: i)));

                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: weekDays.map((date) {
                        final truncated = _truncateDate(date);
                        final isSelected = truncated == _selectedDay;
                        final isToday = truncated == today;
                        final items = _transcriptsByDate[truncated];
                        final hasRecordings = items != null && items.isNotEmpty;
                        final count = items?.length ?? 0;

                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2.5),
                            child: _WeekDayCard(
                              date: date,
                              isSelected: isSelected,
                              isToday: isToday,
                              hasRecordings: hasRecordings,
                              count: count,
                              isDark: isDark,
                              onTap: () => _selectDay(date),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 14),

            // 3. Selected Date Section Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _formatSelectedDayHeader(_selectedDay),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                      color: fg,
                    ),
                  ),
                  if (selectedDayTranscripts.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1A2433) : const Color(0xFFEAF2FF),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${selectedDayTranscripts.length} recording${selectedDayTranscripts.length == 1 ? '' : 's'} • ${_fmtDurationShort(dayTotalSec)}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF007AFF),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 10),

            // 4. Smooth Scrollable Day Agenda List (Fluid BouncingScrollPhysics)
            Expanded(
              child: RefreshIndicator(
                onRefresh: _loadTranscripts,
                color: const Color(0xFF007AFF),
                child: selectedDayTranscripts.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                        children: [
                          GlassCard(
                            variant: GlassCardVariant.tile,
                            padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 52,
                                  height: 52,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: isDark ? const Color(0xFF1F1F2B) : const Color(0xFFEFF0F6),
                                  ),
                                  child: Icon(
                                    Icons.event_available_rounded,
                                    size: 26,
                                    color: muted,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  'No recordings on this date',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                    color: fg,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  'No transcripts found for this date.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w500,
                                    color: muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                        itemCount: selectedDayTranscripts.length,
                        itemBuilder: (context, index) {
                          final item = selectedDayTranscripts[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _TimelineTranscriptCard(
                              transcript: item,
                              timeText: _fmtTime(item.createdAt.toLocal()),
                              durationText: _fmtDurationShort(item.durationSec),
                              isDark: isDark,
                              onTap: () => _openTranscript(item),
                            ),
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
}

// --------------------------------------------------------------------------
// Custom Components
// --------------------------------------------------------------------------

class _WeekDayCard extends StatelessWidget {
  const _WeekDayCard({
    required this.date,
    required this.isSelected,
    required this.isToday,
    required this.hasRecordings,
    required this.count,
    required this.isDark,
    required this.onTap,
  });

  final DateTime date;
  final bool isSelected;
  final bool isToday;
  final bool hasRecordings;
  final int count;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    const weekLetters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final letter = weekLetters[date.weekday - 1];

    if (isSelected) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF007AFF),
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                letter,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${date.day}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 3),
              if (hasRecordings)
                Container(
                  width: 5,
                  height: 5,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                  ),
                )
              else
                const SizedBox(height: 5),
            ],
          ),
        ),
      );
    }

    Color bg;
    Color border;

    if (hasRecordings) {
      bg = isDark ? const Color(0xFF20202A) : const Color(0xFFEAEAEE);
      border = isDark ? const Color(0xFF323240) : const Color(0xFFD6D6DF);
    } else {
      bg = isDark ? GlassTokens.surfaceDark : GlassTokens.surfaceLight;
      border = isDark ? GlassTokens.borderDark : GlassTokens.borderLight;
    }

    if (isToday) {
      border = const Color(0xFF007AFF);
    }

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: border,
            width: isToday ? 1.5 : 1.0,
          ),
        ),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              letter,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: isToday ? const Color(0xFF007AFF) : muted,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '${date.day}',
              style: TextStyle(
                fontSize: 15.5,
                fontWeight: isToday || hasRecordings ? FontWeight.w800 : FontWeight.w600,
                color: isToday ? const Color(0xFF007AFF) : fg,
              ),
            ),
            const SizedBox(height: 3),
            if (hasRecordings)
              Container(
                width: 5,
                height: 5,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF007AFF),
                ),
              )
            else
              const SizedBox(height: 5),
          ],
        ),
      ),
    );
  }
}

class _TimelineTranscriptCard extends StatelessWidget {
  const _TimelineTranscriptCard({
    required this.transcript,
    required this.timeText,
    required this.durationText,
    required this.isDark,
    required this.onTap,
  });

  final TranscriptEntity transcript;
  final String timeText;
  final String durationText;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    final title = (transcript.title?.trim().isNotEmpty ?? false)
        ? transcript.title!.trim()
        : 'Untitled Recording';

    // Source styling
    final (IconData icon, Color iconColor, Color iconBg) = switch (transcript.sourceType) {
      1 => (
          Icons.smart_display_rounded,
          const Color(0xFFFF3B30),
          isDark ? const Color(0xFF382024) : const Color(0xFFFFEAEA),
        ),
      2 => (
          Icons.audio_file_rounded,
          const Color(0xFF007AFF),
          isDark ? const Color(0xFF1E2A3A) : const Color(0xFFE8F1FF),
        ),
      3 => (
          Icons.video_file_rounded,
          const Color(0xFF635BFF),
          isDark ? const Color(0xFF242238) : const Color(0xFFF0EFFF),
        ),
      _ => (
          Icons.mic_rounded,
          const Color(0xFF007AFF),
          isDark ? const Color(0xFF1E2A3A) : const Color(0xFFEBF3FF),
        ),
    };

    return GlassCard(
      variant: GlassCardVariant.tile,
      padding: const EdgeInsets.all(14),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Icon badge
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Center(
              child: Icon(icon, size: 22, color: iconColor),
            ),
          ),

          const SizedBox(width: 14),

          // Details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.1,
                    color: fg,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Icon(
                      Icons.schedule_rounded,
                      size: 13,
                      color: muted,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      timeText,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: muted,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 3,
                      height: 3,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: muted.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      durationText,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: muted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // Trailing Action Chevron
          Icon(
            Icons.chevron_right_rounded,
            size: 22,
            color: muted.withValues(alpha: 0.6),
          ),
        ],
      ),
    );
  }
}
