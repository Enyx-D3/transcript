// lib/tabs/timeline_tab.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transcript/transcript/import_audio_sheet.dart';
import 'package:transcript/transcript/import_video_sheet.dart';
import 'package:transcript/ui/glass/glass_button.dart';
import 'package:transcript/widgets/empty_state.dart';
import 'package:transcript/widgets/leading_pill_icon.dart';
import 'package:transcript/widgets/source_tag.dart';

import '../onboarding/enroll_flow.dart';
import '../debug/speaker_memory_page.dart';
import '../objectbox/entities.dart';
import '../objectbox/objectbox_store.dart';
import '../objectbox.g.dart';
import '../transcript/transcript_detail_page.dart';

import '../common/confirm_dialog.dart';
import '../common/app_flushbar.dart';
import '../settings/settings_page.dart';
import '../transcript/transcript_youtube_page.dart';
import '../transcript/youtube_saved_detail_page.dart';

// ✅ Qwen model download service
import '../qwen_model_service.dart';

// ✅ ModelProgress type
import '../model_progress.dart';
import '../paywall/paywall_page.dart';

import '../rate/rate_gate.dart';
import '../rate/rate_prompt_dialog.dart';

// ✅ Glass primitives
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';

enum _TranscriptSort {
  dateDesc, // default (current first)
  dateAsc,
  titleAsc,
  titleDesc,
}

class TimelineTab extends StatefulWidget {
  const TimelineTab({
    super.key,
    required this.onNavigateToTab,
    this.onUpgradeSuccess,
  });

  final void Function(int tabIndex) onNavigateToTab;

  /// ✅ Passed from HomeShell → Timeline → Settings → Account
  final VoidCallback? onUpgradeSuccess;

  @override
  State<TimelineTab> createState() => _TimelineTabState();
}

class _TimelineTabState extends State<TimelineTab> {
  final ScrollController _recentCtrl = ScrollController();

  List<TranscriptEntity> _items = [];
  bool _loading = false;

  // --------------------
  // Qwen model state
  // --------------------
  final QwenModelService _qwen = QwenModelService();
  bool _qwenDownloaded = false;

  StreamSubscription<ModelProgress>? _qwenSub;
  ModelProgress _qwenProgress = ModelProgress.idle;

  static const _kPaywallSeenOnce = 'paywall_seen_once';
  bool _paywallCheckedThisOpen = false;
  bool _rateCheckedThisOpen = false;

  _TranscriptSort _sort = _TranscriptSort.dateDesc;

  static const String _kPrefDefaultLang = 'pref_default_lang';
  static const String _kLangPromptSeenOnce = 'pref_lang_prompt_seen_once';

  static const Map<String, String> _langOptions = {
    'en': 'English',
    'es': 'Spanish',
    'fr': 'French',
    'ar': 'Arabic',
    'pt': 'Portuguese',
    'it': 'Italian',
    'zh': 'Chinese',
    'auto': 'Auto',
  };

  // ✅ prevent setState after dispose
  bool _disposed = false;
  void _ss(VoidCallback fn) {
    if (!mounted || _disposed) return;
    setState(fn);
  }

  @override
  void initState() {
    super.initState();

    _load();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _disposed) return;

      await _maybeShowPaywallOnce();

      if (!mounted || _disposed) return;
      await _maybeShowRatePrompt();
    });

    _qwenSub = _qwen.progress.listen((p) async {
      if (!mounted || _disposed) return;
      _ss(() => _qwenProgress = p);

      // if finished successfully, refresh downloaded state
      final finishedOk =
          !p.downloading && p.error == null && p.total == 1 && p.received == 1;
      if (finishedOk) {
        final ok = await _qwen.isModelDownloaded();
        if (!mounted || _disposed) return;
        _ss(() => _qwenDownloaded = ok);
      }
    });

    // Run after first frame (safe place to start background work)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _disposed) return;
      _ensureModelDownloading();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _qwenSub?.cancel();
    _recentCtrl.dispose();
    super.dispose();
  }

  void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

  // --------------------
  // ✅ Auto-download flow (NO confirmation)
  // --------------------
  Future<void> _ensureModelDownloading() async {
    try {
      final downloaded = await _qwen.isModelDownloaded();
      if (!mounted || _disposed) return;
      _ss(() => _qwenDownloaded = downloaded);

      // If not downloaded, just start download
      if (!downloaded) {
        await _qwen.downloadModel();
      }
    } catch (_) {}
  }

  Future<void> _comingSoon() async {
    if (!mounted || _disposed) return;
    await AppFlushbar.info(context, message: 'Coming Soon!');
  }

  // --------------------
  // Filter
  // --------------------

  String _displayTitle(TranscriptEntity t) {
    final raw = t.title?.trim() ?? '';
    return raw.isNotEmpty ? raw : 'Untitled transcript';
  }

  int _cmpTitle(TranscriptEntity a, TranscriptEntity b) {
    final ta = _displayTitle(a).toLowerCase();
    final tb = _displayTitle(b).toLowerCase();
    return ta.compareTo(tb);
  }

  void _applySortInMemory() {
    if (_items.isEmpty) return;

    switch (_sort) {
      case _TranscriptSort.dateDesc:
        _items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        break;
      case _TranscriptSort.dateAsc:
        _items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        break;
      case _TranscriptSort.titleAsc:
        _items.sort(_cmpTitle);
        break;
      case _TranscriptSort.titleDesc:
        _items.sort((a, b) => _cmpTitle(b, a));
        break;
    }
  }

  Future<void> _showTranscriptSortSheet() async {
    if (!mounted || _disposed) return;

    final picked = await showModalBottomSheet<_TranscriptSort>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        Widget tile(
          _TranscriptSort v,
          String title,
          String subtitle,
          IconData ic,
        ) {
          final selected = _sort == v;
          return ListTile(
            leading: Icon(ic, color: Colors.white.withValues(alpha: 0.86)),
            title: Text(
              title,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.92),
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.70),
                fontWeight: FontWeight.w600,
              ),
            ),
            trailing: selected
                ? Icon(Icons.check, color: Colors.white.withValues(alpha: 0.92))
                : null,
            onTap: () => Navigator.of(ctx).pop(v),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: GlassCard(
              variant: GlassCardVariant.panel,
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 6),
                  tile(
                    _TranscriptSort.dateDesc,
                    'Date',
                    'Newest → Oldest',
                    Icons.schedule,
                  ),
                  tile(
                    _TranscriptSort.dateAsc,
                    'Date',
                    'Oldest → Newest',
                    Icons.schedule,
                  ),
                  tile(
                    _TranscriptSort.titleAsc,
                    'Title',
                    'A → Z',
                    Icons.sort_by_alpha,
                  ),
                  tile(
                    _TranscriptSort.titleDesc,
                    'Title',
                    'Z → A',
                    Icons.sort_by_alpha,
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (picked == null) return;

    _ss(() => _sort = picked);

    // ✅ Reuse refresh/load behavior
    await _load();
  }

  // --------------------
  // Favourite
  // --------------------
  Future<void> _toggleFavourite(TranscriptEntity t) async {
    final store = ObjectBox.I.store;
    final box = store.box<TranscriptEntity>();

    final newVal = !t.isFavourite;

    store.runInTransaction(TxMode.write, () {
      final fresh = box.get(t.id);
      if (fresh == null) return;
      fresh.isFavourite = newVal;
      fresh.updatedAt = DateTime.now();
      box.put(fresh);
    });

    // ✅ Update the current list item without full reload
    if (!mounted || _disposed) return;
    _ss(() {
      t.isFavourite = newVal;
    });
  }

  // --------------------
  // Language + Paywall
  // --------------------

  Future<void> _maybePickLanguageOnceWithDropdown() async {
    if (!mounted || _disposed) return;

    final sp = await SharedPreferences.getInstance();

    // ✅ only once
    final seen = sp.getBool(_kLangPromptSeenOnce) ?? false;
    if (seen) return;

    // current value (default to 'en' if missing/invalid)
    final current = sp.getString(_kPrefDefaultLang);
    String selected = _langOptions.containsKey(current) ? current! : 'en';

    final picked = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: Colors.transparent,
              contentPadding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              content: GlassCard(
                variant: GlassCardVariant.panel,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Choose Default Language',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.92),
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: selected,
                      isExpanded: true,
                      items: _langOptions.entries
                          .map(
                            (e) => DropdownMenuItem<String>(
                              value: e.key,
                              child: Text(
                                e.value,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.92),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        setLocal(() => selected = v);
                      },
                      dropdownColor: const Color.fromARGB(190, 0, 0, 0),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 10,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(
                            color: Colors.white.withValues(alpha: 0.22),
                            width: 1,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(
                            color: Colors.white.withValues(alpha: 0.32),
                            width: 1.2,
                          ),
                        ),
                        border: OutlineInputBorder(
                          borderSide: BorderSide(
                            color: Colors.white.withValues(alpha: 0.22),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'You can change the language later when transcribing.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        // Expanded(
                        //   child: TextButton(
                        //     onPressed: () => Navigator.of(ctx).pop(null),
                        //     child: Text(
                        //       'Cancel',
                        //       style: TextStyle(
                        //         color: Colors.white.withValues(alpha: 0.86),
                        //         fontWeight: FontWeight.w600,
                        //       ),
                        //     ),
                        //   ),
                        // ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: GlassButton(
                            kind: GlassButtonKind.secondary,
                            label: 'Continue',
                            onPressed: () => Navigator.of(ctx).pop(selected),
                          ),
                          // child: FilledButton(
                          //   style: FilledButton.styleFrom(
                          //     backgroundColor: Colors.white.withValues(
                          //       alpha: 0.92,
                          //     ),
                          //     foregroundColor: Colors.black,
                          //   ),
                          //   onPressed: () => Navigator.of(ctx).pop(selected),
                          //   child: const Text('Continue'),
                          // ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    // If user cancels, do NOT mark as seen (so it can show again next time)
    if (picked == null) {
      await sp.setBool(_kLangPromptSeenOnce, true);
      return;
    }

    await sp.setString(_kPrefDefaultLang, picked);
    await sp.setBool(_kLangPromptSeenOnce, true);
  }

  Future<void> _maybeShowPaywallOnce() async {
    if (_paywallCheckedThisOpen) return;
    _paywallCheckedThisOpen = true;

    final sp = await SharedPreferences.getInstance();
    final seen = sp.getBool(_kPaywallSeenOnce) ?? false;
    if (seen || !mounted || _disposed) return;

    // ✅ show language prompt once BEFORE paywall
    await _maybePickLanguageOnceWithDropdown();
    if (!mounted || _disposed) return;

    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted || _disposed) return;

    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PaywallPage(
          onClose: () async {
            await sp.setBool(_kPaywallSeenOnce, true);
          },
          onContinue: (_) async {
            await sp.setBool(_kPaywallSeenOnce, true);

            // ✅ Now: open Settings -> Account (no Account tab)
            if (!mounted || _disposed) return;
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsPage(
                  openAccount: true,
                  onUpgradeSuccess: widget.onUpgradeSuccess,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> debugResetOnboardingFlags({bool clearLanguage = true}) async {
    final sp = await SharedPreferences.getInstance();

    // Seen-once flags
    await sp.setBool(_kLangPromptSeenOnce, false);
    await sp.setBool(_kPaywallSeenOnce, false);

    // Optional: also clear chosen language
    if (clearLanguage) {
      await sp.remove(_kPrefDefaultLang);
    }

    debugPrint(
      '[DEBUG] Onboarding flags reset: '
      'langPromptSeen=false, paywallSeen=false, '
      'languageCleared=$clearLanguage',
    );
  }

  Future<void> _openPaywallDebug() async {
    if (!mounted || _disposed) return;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PaywallPage(
          onClose: () async {},
          onContinue: (_) async {
            if (!mounted || _disposed) return;
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsPage(
                  openAccount: true,
                  onUpgradeSuccess: widget.onUpgradeSuccess,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ============================================================
  // ✅ In app review helper
  // ============================================================

  Future<void> _maybeShowRatePrompt() async {
    if (_rateCheckedThisOpen) return;
    _rateCheckedThisOpen = true;

    // if you want to avoid stacking with paywall on first open:
    if (!_paywallCheckedThisOpen) return;

    final ok = await RateGate.shouldPrompt();
    if (!ok || !mounted || _disposed) return;

    await showRatePrompt(context);
  }

  // --------------------
  // Timeline load + delete
  // --------------------
  Future<void> _load() async {
    if (_loading) return;
    if (!mounted || _disposed) return;

    _ss(() => _loading = true);

    try {
      await _purgeTrashExpired();

      final box = ObjectBox.I.transcripts;

      Query<TranscriptEntity>? q;
      try {
        // ✅ Keep date sort fast in ObjectBox when sorting by date
        final qb = box.query(TranscriptEntity_.isDeleted.equals(false));

        if (_sort == _TranscriptSort.dateAsc) {
          qb.order(TranscriptEntity_.createdAt, flags: 0);
        } else {
          // default + dateDesc + title sorts (we’ll sort titles in-memory)
          qb.order(TranscriptEntity_.createdAt, flags: Order.descending);
        }

        q = qb.build();
        final rows = q.find();
        _items = rows;

        // ✅ For title sorting, do it in-memory
        if (_sort == _TranscriptSort.titleAsc ||
            _sort == _TranscriptSort.titleDesc) {
          _applySortInMemory();
        }
      } finally {
        q?.close();
      }
    } finally {
      _ss(() => _loading = false);
    }
  }

  Future<void> _moveToTrash(int transcriptId) async {
    final store = ObjectBox.I.store;
    final box = store.box<TranscriptEntity>();

    store.runInTransaction(TxMode.write, () {
      final t = box.get(transcriptId);
      if (t == null) return;

      t.isDeleted = true;
      t.deletedAt = DateTime.now();
      t.updatedAt = DateTime.now();

      box.put(t);
    });

    await _load();
  }

  Future<void> _deleteTranscriptCascade(
    int transcriptId, {
    bool refresh = true,
  }) async {
    final store = ObjectBox.I.store;

    final transcriptsBox = store.box<TranscriptEntity>();
    final turnsBox = store.box<TranscriptTurnEntity>();
    final summaryBox = store.box<TranscriptSummaryEntity>();
    final chatsBox = store.box<TranscriptChatMessageEntity>();

    // ✅ youtube boxes
    final ytMetaBox = store.box<YoutubeTranscriptMetaEntity>();
    final ytTextBox = store.box<YoutubeTranscriptTextEntity>();

    final transcript = transcriptsBox.get(transcriptId);

    final isYoutube = (transcript?.sourceType ?? 0) == 1;
    final ytMetaId = transcript?.youtubeMetaId;

    final audioPath = transcript?.audioPath;
    if (!isYoutube && audioPath != null && audioPath.trim().isNotEmpty) {
      try {
        final f = File(audioPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }

    store.runInTransaction(TxMode.write, () {
      if (!isYoutube) {
        final turnsQ = turnsBox
            .query(TranscriptTurnEntity_.transcript.equals(transcriptId))
            .build();
        try {
          final ids = turnsQ.findIds();
          if (ids.isNotEmpty) turnsBox.removeMany(ids);
        } finally {
          turnsQ.close();
        }

        final sumQ = summaryBox
            .query(TranscriptSummaryEntity_.transcriptId.equals(transcriptId))
            .build();
        try {
          final ids = sumQ.findIds();
          if (ids.isNotEmpty) summaryBox.removeMany(ids);
        } finally {
          sumQ.close();
        }

        final chatQ = chatsBox
            .query(
              TranscriptChatMessageEntity_.transcriptId.equals(transcriptId),
            )
            .build();
        try {
          final ids = chatQ.findIds();
          if (ids.isNotEmpty) chatsBox.removeMany(ids);
        } finally {
          chatQ.close();
        }
      }

      if (isYoutube && ytMetaId != null) {
        final tq = ytTextBox
            .query(YoutubeTranscriptTextEntity_.meta.equals(ytMetaId))
            .build();
        try {
          final ids = tq.findIds();
          if (ids.isNotEmpty) ytTextBox.removeMany(ids);
        } finally {
          tq.close();
        }
        ytMetaBox.remove(ytMetaId);
      }

      transcriptsBox.remove(transcriptId);
    });

    if (refresh) {
      await _load();
    }
  }

  Future<void> _onDeletePressed(TranscriptEntity t) async {
    _unfocus();

    final ok = await showConfirmDeleteDialog(
      context,
      title: 'Move to Trash?',
      message:
          'This transcript will be moved to Trash. It will be permanently deleted after 3 days.',
    );
    if (!ok) return;

    await _moveToTrash(t.id);

    if (!mounted || _disposed) return;
    await AppFlushbar.success(context, message: 'Moved to Trash');
  }

  Future<void> _purgeTrashExpired() async {
    final store = ObjectBox.I.store;
    final transcriptsBox = store.box<TranscriptEntity>();

    final cutoff = DateTime.now()
        .subtract(const Duration(days: 3))
        .millisecondsSinceEpoch;

    final q = transcriptsBox
        .query(
          TranscriptEntity_.isDeleted
              .equals(true)
              .and(TranscriptEntity_.deletedAt.notNull())
              .and(TranscriptEntity_.deletedAt.lessThan(cutoff)),
        )
        .build();

    final expiredIds = q.findIds();
    q.close();

    for (final id in expiredIds) {
      await _deleteTranscriptCascade(id, refresh: false);
      if (!mounted || _disposed) return;
    }
  }

  Future<void> _openPage(Widget page) async {
    _unfocus();
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    _unfocus();
    await _load();
  }

  // ✅ Small tag beside Timeline (NO blur, NO grain)
  Widget _modelDownloadingTag(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: LiquidGlass(
        borderRadius: BorderRadius.circular(999),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        shadow: false,

        // ✅ PERF: disable expensive effects for small tag
        blurX: 0,
        blurY: 0,
        grain: false,

        tintOpacityDark: 0.040,
        tintOpacityLight: 0.035,
        borderOpacityDark: 0.16,
        borderOpacityLight: 0.18,
        child: Text(
          'MODEL DOWNLOADING',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.25,
            color: Colors.white.withValues(alpha: 0.92),
            fontSize: 10,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final showModelDownloading = _qwenProgress.downloading;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _unfocus,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              children: [
                // ---------- Fixed header ----------
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'Timeline',
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.2,
                                  color: Colors.white.withValues(alpha: 0.92),
                                ),
                              ),
                              if (showModelDownloading)
                                _modelDownloadingTag(isDark),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Your recent recordings and transcripts',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.70)
                                  : Colors.black.withValues(alpha: 0.54),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Settings',
                          onPressed: () => _openPage(
                            SettingsPage(
                              onUpgradeSuccess: widget.onUpgradeSuccess,
                            ),
                          ),
                          onLongPress: () async {
                            await debugResetOnboardingFlags();
                          },
                          icon: Icon(
                            Icons.settings,
                            color: Colors.white.withValues(alpha: 0.88),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 14),

                // ---------- Fixed quick actions ----------
                const _SectionHeaderWithoutSubtitle(title: 'Quick actions'),
                const SizedBox(height: 10),

                _QuickActionGrid(
                  children: [
                    _QuickTile(
                      icon: Icons.people,
                      label: 'Enroll Voice',
                      onTap: () => _openPage(const EnrollmentFlowPage()),
                    ),
                    _QuickTile(
                      icon: Icons.person_search,
                      label: 'People',
                      onTap: () => _openPage(const SpeakerMemoryPage()),
                    ),
                    _QuickTile(
                      icon: Icons.video_library_outlined,
                      label: 'YouTube Transcript',
                      onTap: () => _openPage(const TranscriptYoutubePage()),
                    ),
                    _QuickTile(
                      icon: Icons.audio_file,
                      label: 'Audio File',
                      onTap: () => ImportAudioSheet.show(context),
                    ),
                    _QuickTile(
                      icon: Icons.video_file,
                      label: 'Video File',
                      onTap: () => ImportVideoSheet.show(context),
                    ),
                    _QuickTile(
                      icon: Icons.call,
                      label: 'Phone Call',
                      onTap: () => _comingSoon(),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // ---------- Fixed transcripts header row ----------
                _SectionHeader(
                  title: 'Transcripts',
                  subtitle: _items.isEmpty
                      ? 'Nothing here yet (Refresh to fetch latest)'
                      : '${_items.length} item${_items.length == 1 ? '' : 's'} (Refresh to fetch latest)',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Sort',
                        icon: Icon(
                          Icons.sort,
                          color: Colors.white.withValues(alpha: 0.86),
                        ),
                        onPressed: _showTranscriptSortSheet,
                      ),
                      IconButton(
                        tooltip: 'Reload',
                        onPressed: _loading ? null : _load,
                        icon: _loading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                Icons.refresh,
                                color: Colors.white.withValues(alpha: 0.86),
                              ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 10),

                // ✅ ONLY THIS AREA SCROLLS (Glass panel)
                Expanded(
                  child: GlassCard(
                    variant: GlassCardVariant.tile,
                    padding: EdgeInsets.zero,
                    child: _items.isEmpty
                        ? const EmptyState(
                            title: 'No transcripts yet',
                            subtitle:
                                'Your transcripts will appear here after you record.',
                            icon: Icons.dangerous,
                          )
                        : _buildList(),
                  ),
                ),

                const SizedBox(height: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildList() {
    return ListView.separated(
      itemCount: _items.length,
      padding: EdgeInsets.zero,
      physics: const BouncingScrollPhysics(),

      // ✅ PERF: keep backdrop behavior stable + reduce layer churn
      addRepaintBoundaries: false,
      addAutomaticKeepAlives: false,

      separatorBuilder: (_, _) => const GlassDivider(),
      itemBuilder: (ctx, i) {
        final t = _items[i];

        final title = (t.title?.trim().isNotEmpty ?? false)
            ? t.title!.trim()
            : 'Untitled transcript';
        debugPrint(t.fullTextCache);
        final st =
            t.sourceType; // 0=record, 1=youtube, 2=audio import, 3=video import

        final isYoutube = st == 1;
        final isAudio = st == 2;
        final isVideo = st == 3;

        final IconData leadingIcon = isYoutube
            ? Icons.subtitles
            : (isAudio
                  ? Icons.audio_file
                  : (isVideo ? Icons.video_file : Icons.article_outlined));

        final Widget? tag = isYoutube
            ? const SourceTag(type: 'youtube', label: 'YOUTUBE')
            : (isAudio
                  ? const SourceTag(type: 'audio', label: 'AUDIO')
                  : (isVideo
                        ? const SourceTag(type: 'video', label: 'VIDEO')
                        : null));

        final sub = (isYoutube || isAudio || isVideo)
            ? _fmtDate(t.createdAt)
            : '${_fmtDate(t.createdAt)} • ${_fmtDuration(t.durationSec)}';

        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 4,
          ),
          leading: LeadingPillIcon(icon: leadingIcon),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.92),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (tag != null) ...[const SizedBox(width: 8), tag],
            ],
          ),
          subtitle: Text(
            sub,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.70),
              fontWeight: FontWeight.w600,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: t.isFavourite ? 'Unfavourite' : 'Favourite',
                icon: Icon(
                  t.isFavourite ? Icons.favorite : Icons.favorite_border,
                  color: Colors.white.withValues(
                    alpha: t.isFavourite ? 0.92 : 0.72,
                  ),
                ),
                onPressed: () => _toggleFavourite(t),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: Icon(
                  Icons.delete_outline,
                  color: Colors.white.withValues(alpha: 0.62),
                ),
                onPressed: () async => _onDeletePressed(t),
              ),
            ],
          ),
          onTap: () async {
            _unfocus();

            if (isYoutube) {
              final metaId = t.youtubeMetaId;
              if (metaId == null) {
                if (!mounted || _disposed) return;
                await AppFlushbar.success(
                  context,
                  message: 'Missing YouTube transcript reference',
                );
                return;
              }
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

            _unfocus();
            await _load();
          },
        );
      },
    );
  }

  String _fmtDate(DateTime dt) {
    final l = dt.toLocal();
    final y = l.year.toString().padLeft(4, '0');
    final m = l.month.toString().padLeft(2, '0');
    final d = l.day.toString().padLeft(2, '0');
    final hh = l.hour.toString().padLeft(2, '0');
    final mm = l.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }

  String _fmtDuration(double sec) {
    final s = sec.isFinite && sec >= 0 ? sec : 0.0;
    final total = s.round();
    final m = (total ~/ 60).toString();
    final ss = (total % 60).toString().padLeft(2, '0');
    return '${m}m${ss}s';
  }
}

// ---------------- UI widgets below (Glass) ----------------

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withValues(alpha: 0.92),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.70)
                        : Colors.black.withValues(alpha: 0.54),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _SectionHeaderWithoutSubtitle extends StatelessWidget {
  const _SectionHeaderWithoutSubtitle({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: Colors.white.withValues(alpha: 0.92),
              ),
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _QuickActionGrid extends StatelessWidget {
  const _QuickActionGrid({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      variant: GlassCardVariant.tile,
      padding: const EdgeInsets.all(10),
      child: GridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 2.9,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: children,
      ),
    );
  }
}

class _QuickTile extends StatelessWidget {
  const _QuickTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => onTap(),
      child: LiquidGlass(
        borderRadius: BorderRadius.circular(16),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shadow: false,

        // ✅ PERF: tiles are interactive + many on screen → no blur/grain
        blurX: 0,
        blurY: 0,
        grain: false,

        tintOpacityDark: 0.050,
        tintOpacityLight: 0.040,
        borderOpacityDark: 0.14,
        borderOpacityLight: 0.18,
        child: Row(
          children: [
            // ✅ PERF: remove nested blur glass — make icon pill tint-only
            LiquidGlass(
              borderRadius: BorderRadius.circular(14),
              padding: const EdgeInsets.all(10),
              shadow: false,

              blurX: 0,
              blurY: 0,
              grain: false,

              tintOpacityDark: 0.030,
              tintOpacityLight: 0.026,
              borderOpacityDark: 0.10,
              borderOpacityLight: 0.12,
              child: Icon(
                icon,
                size: 18,
                color: Colors.white.withValues(alpha: 0.90),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.92),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
