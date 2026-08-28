// lib/tabs/timeline_tab.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transcript/transcript/import_audio_sheet.dart';
import 'package:transcript/transcript/import_video_sheet.dart';
import 'package:transcript/ui/glass/glass_button.dart';
import 'package:transcript/widgets/empty_state.dart';
import '../widgets/icon_pill_button.dart';

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
import '../model_picker_page.dart';
import '../paywall/paywall_page.dart';

import '../rate/rate_gate.dart';
import '../rate/rate_prompt_dialog.dart';

// ✅ Glass primitives
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_card.dart';
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
    this.devBypassPremium = false,
  });

  final void Function(int tabIndex) onNavigateToTab;

  /// ✅ Passed from HomeShell → Timeline → Settings → Account
  final VoidCallback? onUpgradeSuccess;
  final bool devBypassPremium;

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
        final fg = GlassTokens.fg(ctx);
        final muted = GlassTokens.muted(ctx);

        Widget tile(
          _TranscriptSort v,
          String title,
          String subtitle,
          IconData ic,
        ) {
          final selected = _sort == v;
          return ListTile(
            leading: Icon(ic, color: fg),
            title: Text(
              title,
              style: TextStyle(color: fg, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(color: muted, fontWeight: FontWeight.w600),
            ),
            trailing: selected ? Icon(Icons.check, color: fg) : null,
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
        final fg = GlassTokens.fg(ctx);
        final muted = GlassTokens.muted(ctx);
        final isDark = GlassTokens.isDark(ctx);

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
                        color: fg,
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
                                  color: fg,
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
                      dropdownColor: isDark
                          ? const Color(0xFF1E1E26)
                          : const Color(0xFFFFFFFF),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 10,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.22)
                                : Colors.black.withValues(alpha: 0.22),
                            width: 1,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.40)
                                : Colors.black.withValues(alpha: 0.40),
                            width: 1.2,
                          ),
                        ),
                        border: OutlineInputBorder(
                          borderSide: BorderSide(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.22)
                                : Colors.black.withValues(alpha: 0.22),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'You can change the language later when transcribing.',
                      style: TextStyle(
                        color: muted,
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
    if (Platform.isIOS) return;
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
          onPremiumUnlocked: () async {
            await sp.setBool(_kPaywallSeenOnce, true);
            widget.onUpgradeSuccess?.call();
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
          onPremiumUnlocked: () async {
            widget.onUpgradeSuccess?.call();
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

  // ✅ Small tag beside Timeline (Solid, theme-aware)
  Widget _modelDownloadingTag(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final pct = (_qwenProgress.percent * 100).clamp(0, 100).toInt();
    final label = pct > 0 ? 'DOWNLOADING $pct%' : 'DOWNLOADING';

    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: GestureDetector(
        onTap: () => _openPage(const ModelPickerPage()),
        child: LiquidGlass(
          borderRadius: BorderRadius.circular(999),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          backgroundColor: isDark
              ? GlassTokens.surfaceDark
              : GlassTokens.surfaceLight,
          borderColor: isDark
              ? GlassTokens.borderDark
              : GlassTokens.borderLight,
          shadow: false,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  value: _qwenProgress.percent > 0
                      ? _qwenProgress.percent
                      : null,
                  color: fg,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.25,
                  color: fg,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showModelDownloading = _qwenProgress.downloading;

    final fg = GlassTokens.fg(context);

    return Scaffold(
      backgroundColor: GlassTokens.backgroundColor(context),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _unfocus,
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: _load,
            color: GlassTokens.primary(context),
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ---------- Top Header Row ----------
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Text(
                                    'Timeline',
                                    style: TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w800,
                                      color: fg,
                                      letterSpacing: -0.4,
                                    ),
                                  ),
                                  if (showModelDownloading)
                                    Flexible(
                                      child: _modelDownloadingTag(context),
                                    ),
                                ],
                              ),
                            ),
                            Transform.translate(
                              offset: const Offset(0, -3),
                              child: IconPillButton(
                                tooltip: 'Settings',
                                icon: Icons.settings_outlined,
                                iconColor: GlassTokens.primary(context),
                                size: 23,
                                padding: const EdgeInsets.all(9),
                                onTap: () => _openPage(
                                  SettingsPage(
                                    onUpgradeSuccess: widget.onUpgradeSuccess,
                                    devBypassPremium: widget.devBypassPremium,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 16),

                        // ---------- Quick Action Cards Row (Horizontal Scroll) ----------
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          clipBehavior: Clip.none,
                          child: Row(
                            children: [
                              // 1. Record Meeting
                              _TimelineActionCard(
                                title: 'Record',
                                subtitle: 'Meeting',
                                icon: Icons.mic_rounded,
                                iconColor: GlassTokens.primary(context),
                                onTap: () => widget.onNavigateToTab(2),
                              ),
                              // 2. Import File
                              _TimelineActionCard(
                                title: 'Import',
                                subtitle: 'Audio / Video',
                                icon: Icons.folder_rounded,
                                iconColor: GlassTokens.primary(context),
                                onTap: () => _showImportOptions(context),
                              ),
                              // 3. YouTube Transcript
                              _TimelineActionCard(
                                title: 'YouTube',
                                subtitle: 'Transcript',
                                icon: Icons.smart_display_rounded,
                                iconColor: const Color(0xFFFF3B30),
                                onTap: () =>
                                    _openPage(const TranscriptYoutubePage()),
                              ),
                              // 4. Enroll Voice
                              _TimelineActionCard(
                                title: 'Enroll Voice',
                                subtitle: 'Speaker',
                                icon: Icons.record_voice_over_rounded,
                                iconColor: const Color(0xFF00B087),
                                onTap: () =>
                                    _openPage(const EnrollmentFlowPage()),
                              ),
                              // 5. People / Speakers
                              _TimelineActionCard(
                                title: 'People',
                                subtitle: 'Speakers',
                                icon: Icons.people_alt_rounded,
                                iconColor: const Color(0xFF635BFF),
                                onTap: () =>
                                    _openPage(const SpeakerMemoryPage()),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),

                // ---------- Grouped Transcript Slivers ----------
                if (_items.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader(
                            title: 'Today',
                            showActions: true,
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(
                              vertical: 36,
                              horizontal: 24,
                            ),
                            child: Center(
                              child: EmptyState(
                                title: 'No transcripts yet',
                                subtitle:
                                    'Your transcripts will appear here after you record or import.',
                                icon: Icons.article_outlined,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  ..._buildGroupedSlivers(),

                const SliverToBoxAdapter(child: SizedBox(height: 90)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showImportOptions(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF191921) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Import File',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: fg,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Choose media type to transcribe',
                style: TextStyle(fontSize: 13, color: muted),
              ),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF1E2A3A)
                        : const Color(0xFFE8F1FF),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.audio_file_rounded,
                    color: GlassTokens.primary(context),
                  ),
                ),
                title: Text(
                  'Import Audio File',
                  style: TextStyle(fontWeight: FontWeight.w600, color: fg),
                ),
                subtitle: Text(
                  'MP3, WAV, M4A, AAC',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  ImportAudioSheet.show(context);
                },
              ),
              const Divider(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF242238)
                        : const Color(0xFFF0EFFF),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.video_file_rounded,
                    color: Color(0xFF635BFF),
                  ),
                ),
                title: Text(
                  'Import Video File',
                  style: TextStyle(fontWeight: FontWeight.w600, color: fg),
                ),
                subtitle: Text(
                  'MP4, MOV, MKV, AVI',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  ImportVideoSheet.show(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader({
    required String title,
    bool showActions = false,
  }) {
    final fg = GlassTokens.fg(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 0, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 16.5,
              fontWeight: FontWeight.w800,
              color: fg,
              letterSpacing: -0.2,
            ),
          ),
          if (showActions)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _AnimatedSortButton(onTap: _showTranscriptSortSheet),
                const SizedBox(width: 6),
                _AnimatedReloadButton(
                  loading: _loading,
                  onTap: _loading ? null : _load,
                ),
                const SizedBox(width: 4),
              ],
            ),
        ],
      ),
    );
  }

  List<Widget> _buildGroupedSlivers() {
    final groups = _groupTranscripts(_items);
    final slivers = <Widget>[];

    int groupIndex = 0;
    for (final entry in groups.entries) {
      final groupKey = entry.key;
      final list = entry.value;
      final isFirst = groupIndex == 0;
      groupIndex++;

      // Section Header
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: _buildSectionHeader(title: groupKey, showActions: isFirst),
          ),
        ),
      );

      // Section Items
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, i) {
              final t = list[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _TranscriptItemCard(
                  transcript: t,
                  onTap: () => _openDetail(t),
                  onToggleFavourite: () => _toggleFavourite(t),
                  onDelete: () => _onDeletePressed(t),
                ),
              );
            }, childCount: list.length),
          ),
        ),
      );
    }

    return slivers;
  }

  Map<String, List<TranscriptEntity>> _groupTranscripts(
    List<TranscriptEntity> items,
  ) {
    final Map<String, List<TranscriptEntity>> groups = {};
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    for (final t in items) {
      final itemDate = t.createdAt.toLocal();
      final itemDay = DateTime(itemDate.year, itemDate.month, itemDate.day);

      String groupKey;
      if (itemDay.isAtSameMomentAs(today)) {
        groupKey = 'Today';
      } else if (itemDay.isAtSameMomentAs(yesterday)) {
        groupKey = 'Yesterday';
      } else {
        groupKey = 'Earlier';
      }

      groups.putIfAbsent(groupKey, () => []).add(t);
    }
    return groups;
  }

  Future<void> _openDetail(TranscriptEntity t) async {
    _unfocus();
    final isYoutube = t.sourceType == 1;

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
  }
}

// ---------------- UI Action Cards & Items ----------------

class _TimelineActionCard extends StatelessWidget {
  const _TimelineActionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconColor,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    final cardBg = isDark ? const Color(0xFF191922) : const Color(0xFFEBEBF0);

    final borderColor = isDark
        ? const Color(0xFF282834)
        : const Color(0xFFDADAE2);

    return Container(
      width: 108,
      height: 114,
      margin: const EdgeInsets.only(right: 10),
      child: Material(
        color: cardBg,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: borderColor, width: 1),
              boxShadow: [
                BoxShadow(
                  color: isDark
                      ? Colors.black.withValues(alpha: 0.25)
                      : Colors.black.withValues(alpha: 0.03),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 32, color: iconColor),
                const SizedBox(height: 10),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: muted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TranscriptItemCard extends StatelessWidget {
  const _TranscriptItemCard({
    required this.transcript,
    required this.onTap,
    required this.onToggleFavourite,
    required this.onDelete,
  });

  final TranscriptEntity transcript;
  final VoidCallback onTap;
  final VoidCallback onToggleFavourite;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    final title = (transcript.title?.trim().isNotEmpty ?? false)
        ? transcript.title!.trim()
        : 'Untitled transcript';

    final st = transcript.sourceType; // 0=record, 1=youtube, 2=audio, 3=video
    final isYoutube = st == 1;
    final isAudio = st == 2;
    final isVideo = st == 3;

    // Accent bar color on the left edge
    Color accentColor = GlassTokens.primary(context);
    if (isYoutube) accentColor = const Color(0xFFFF3B30);
    if (isVideo) accentColor = const Color(0xFF635BFF);

    // Format subtitle line: e.g. "10:32 AM  •  42:18  •  3 Speakers"
    final l = transcript.createdAt.toLocal();
    final hour = l.hour == 0 ? 12 : (l.hour > 12 ? l.hour - 12 : l.hour);
    final min = l.minute.toString().padLeft(2, '0');
    final ampm = l.hour >= 12 ? 'PM' : 'AM';
    final timeStr = '$hour:$min $ampm';

    final sec = transcript.durationSec.isFinite && transcript.durationSec >= 0
        ? transcript.durationSec.round()
        : 0;
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final ss = (sec % 60).toString().padLeft(2, '0');
    final durStr = h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';

    String typeStr;
    if (isYoutube) {
      typeStr = 'YouTube';
    } else if (isAudio) {
      typeStr = 'Audio File';
    } else if (isVideo) {
      typeStr = 'Video File';
    } else {
      final speakerSet = transcript.turns.map((e) => e.speakerLabel).toSet();
      final count = speakerSet.isNotEmpty ? speakerSet.length : 1;
      typeStr = '$count Speaker${count == 1 ? '' : 's'}';
    }

    final subtitleStr = '$timeStr  •  $durStr  •  $typeStr';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF191922) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? const Color(0xFF282834) : const Color(0xFFEEF0F6),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: 0.2)
                : Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left Accent Line Bar (matching screenshot)
              Container(width: 4.5, color: accentColor),
              Expanded(
                child: InkWell(
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Top Row: Title + 3-dots Popup Menu
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                style: TextStyle(
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w700,
                                  color: fg,
                                  letterSpacing: -0.1,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            PopupMenuButton<String>(
                              icon: Icon(
                                Icons.more_vert_rounded,
                                size: 20,
                                color: muted,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 140),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              onSelected: (val) {
                                if (val == 'fav') {
                                  onToggleFavourite();
                                } else if (val == 'delete') {
                                  onDelete();
                                }
                              },
                              itemBuilder: (ctx) => [
                                PopupMenuItem(
                                  value: 'fav',
                                  child: Row(
                                    children: [
                                      Icon(
                                        transcript.isFavourite
                                            ? Icons.favorite
                                            : Icons.favorite_border,
                                        size: 18,
                                        color: transcript.isFavourite
                                            ? Colors.redAccent
                                            : fg,
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        transcript.isFavourite
                                            ? 'Unfavourite'
                                            : 'Favourite',
                                        style: TextStyle(
                                          fontSize: 13.5,
                                          color: fg,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.delete_outline,
                                        size: 18,
                                        color: Colors.redAccent,
                                      ),
                                      SizedBox(width: 10),
                                      Text(
                                        'Delete',
                                        style: TextStyle(
                                          fontSize: 13.5,
                                          color: Colors.redAccent,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),

                        const SizedBox(height: 6),

                        // Subtitle row & Completed pill tag
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                subtitleStr,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: muted,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Completed Tag Pill
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? const Color(0xFF1E2A3A)
                                    : const Color(0xFFE8F1FF),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                'Completed',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: GlassTokens.primary(context),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
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

// ---------------- ANIMATED BUTTONS ----------------

class _AnimatedReloadButton extends StatefulWidget {
  const _AnimatedReloadButton({required this.onTap, required this.loading});

  final VoidCallback? onTap;
  final bool loading;

  @override
  State<_AnimatedReloadButton> createState() => _AnimatedReloadButtonState();
}

class _AnimatedReloadButtonState extends State<_AnimatedReloadButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _rotationAnim;
  double _touchScale = 1.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
    );

    // Silky smooth 360-degree rotation with seamless cubic ease
    _rotationAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic),
    );

    if (widget.loading) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _AnimatedReloadButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.loading && !oldWidget.loading) {
      _controller.repeat();
    } else if (!widget.loading && oldWidget.loading) {
      _controller.forward().then((_) {
        if (mounted) _controller.reset();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (widget.onTap == null) return;
    HapticFeedback.lightImpact();
    _controller.forward(from: 0.0).then((_) {
      if (mounted && !widget.loading) {
        _controller.reset();
      }
    });
    widget.onTap!();
  }

  @override
  Widget build(BuildContext context) {
    final muted = GlassTokens.muted(context);
    final primaryColor = GlassTokens.primary(context);

    return Tooltip(
      message: 'Reload',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _touchScale = 0.86),
        onTapUp: (_) => setState(() => _touchScale = 1.0),
        onTapCancel: () => setState(() => _touchScale = 1.0),
        onTap: _handleTap,
        child: AnimatedScale(
          scale: _touchScale,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final activeColor = _controller.isAnimating && !widget.loading
                  ? (ColorTween(begin: muted, end: primaryColor).evaluate(
                          CurvedAnimation(
                            parent: _controller,
                            curve: const Interval(
                              0.0,
                              0.4,
                              curve: Curves.easeInOut,
                            ),
                          ),
                        ) ??
                        primaryColor)
                  : (widget.loading ? primaryColor : muted);

              return Padding(
                padding: const EdgeInsets.all(6),
                child: RotationTransition(
                  turns: widget.loading ? _controller : _rotationAnim,
                  child: Icon(
                    Icons.refresh_rounded,
                    size: 21,
                    color: activeColor,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AnimatedSortButton extends StatefulWidget {
  const _AnimatedSortButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_AnimatedSortButton> createState() => _AnimatedSortButtonState();
}

class _AnimatedSortButtonState extends State<_AnimatedSortButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _tiltAnim;
  double _touchScale = 1.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );

    // Smooth subtle tilt swing
    _tiltAnim = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.0,
          end: -0.04,
        ).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 35,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: -0.04,
          end: 0.03,
        ).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 35,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.03,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 30,
      ),
    ]).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    HapticFeedback.lightImpact();
    _controller.forward(from: 0.0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final muted = GlassTokens.muted(context);
    final primaryColor = GlassTokens.primary(context);

    return Tooltip(
      message: 'Sort',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _touchScale = 0.86),
        onTapUp: (_) => setState(() => _touchScale = 1.0),
        onTapCancel: () => setState(() => _touchScale = 1.0),
        onTap: _handleTap,
        child: AnimatedScale(
          scale: _touchScale,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final activeColor = _controller.isAnimating
                  ? (ColorTween(begin: muted, end: primaryColor).evaluate(
                          CurvedAnimation(
                            parent: _controller,
                            curve: const Interval(
                              0.0,
                              0.5,
                              curve: Curves.easeInOut,
                            ),
                          ),
                        ) ??
                        primaryColor)
                  : muted;

              return Transform.rotate(
                angle: _controller.isAnimating ? _tiltAnim.value * 6.28 : 0.0,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.sort_rounded, size: 21, color: activeColor),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
