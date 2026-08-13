// lib/tabs/favourites_tab.dart
import 'package:flutter/material.dart';
import 'package:transcript/widgets/empty_state.dart';
import 'package:transcript/widgets/leading_pill_icon.dart';
import 'package:transcript/widgets/source_tag.dart';

import '../objectbox/entities.dart';
import '../objectbox/objectbox_store.dart';
import '../objectbox.g.dart';

import '../common/app_flushbar.dart';
import '../transcript/transcript_detail_page.dart';
import '../transcript/youtube_saved_detail_page.dart';

// ✅ Glass primitives
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_tokens.dart';

enum _TranscriptSort { dateDesc, dateAsc, titleAsc, titleDesc }

class FavouritesTab extends StatefulWidget {
  const FavouritesTab({super.key});

  @override
  State<FavouritesTab> createState() => _FavouritesTabState();
}

class _FavouritesTabState extends State<FavouritesTab> {
  final ScrollController _ctrl = ScrollController();

  List<TranscriptEntity> _items = [];
  bool _loading = false;

  _TranscriptSort _sort = _TranscriptSort.dateDesc;

  bool _disposed = false;
  void _ss(VoidCallback fn) {
    if (!mounted || _disposed) return;
    setState(fn);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _disposed = true;
    _ctrl.dispose();
    super.dispose();
  }

  void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

  // -----------------------
  // Helpers
  // -----------------------

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

  // -----------------------
  // Data load
  // -----------------------

  Future<void> _load() async {
    if (_loading) return;
    if (!mounted || _disposed) return;

    _ss(() => _loading = true);

    try {
      final box = ObjectBox.I.transcripts;

      Query<TranscriptEntity>? q;
      try {
        final qb = box.query(
          TranscriptEntity_.isDeleted
              .equals(false)
              .and(TranscriptEntity_.isFavourite.equals(true)),
        );

        if (_sort == _TranscriptSort.dateAsc) {
          qb.order(TranscriptEntity_.createdAt, flags: 0);
        } else {
          qb.order(TranscriptEntity_.createdAt, flags: Order.descending);
        }

        q = qb.build();
        _items = q.find();

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

  // -----------------------
  // Sort sheet (glass)
  // -----------------------

  Future<void> _showSortSheet() async {
    if (!mounted || _disposed) return;

    final picked = await showModalBottomSheet<_TranscriptSort>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: false,
      builder: (ctx) {
        final fg = GlassTokens.fg(ctx);
        final muted = GlassTokens.muted(ctx);
        final isDark = GlassTokens.isDark(ctx);

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
              style: TextStyle(
                color: fg,
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(color: muted),
            ),
            trailing: selected
                ? Icon(Icons.check, color: fg)
                : null,
            onTap: () => Navigator.of(ctx).pop(v),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: GlassCard(
              variant: GlassCardVariant.tile,
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 42,
                    height: 5,
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(99),
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.16)
                          : Colors.black.withValues(alpha: 0.16),
                    ),
                  ),
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
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (picked == null) return;

    _ss(() => _sort = picked);
    await _load();
  }

  // -----------------------
  // Favourite toggle
  // -----------------------

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

    if (!mounted || _disposed) return;

    _ss(() {
      t.isFavourite = newVal;
      if (!newVal) _items.removeWhere((x) => x.id == t.id);
    });
  }

  // -----------------------
  // Open transcript
  // -----------------------

  Future<void> _openTranscript(TranscriptEntity t) async {
    _unfocus();

    final isYoutube = (t.sourceType) == 1;
    if (isYoutube) {
      final metaId = t.youtubeMetaId;
      if (metaId == null) {
        if (!mounted || _disposed) return;
        await AppFlushbar.info(
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

  // -----------------------
  // UI
  // -----------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);
    final isDark = GlassTokens.isDark(context);

    final titleStyle = theme.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w900,
      letterSpacing: -0.2,
      color: fg,
    );

    final subStyle = theme.textTheme.bodySmall?.copyWith(
      color: muted,
      fontWeight: FontWeight.w600,
    );

    final showBusy = _loading;

    // ✅ small control pill
    Widget headerPill({required IconData icon, required VoidCallback onTap}) {
      return LiquidGlass(
        borderRadius: BorderRadius.circular(999),
        padding: const EdgeInsets.all(8),
        backgroundColor:
            isDark ? GlassTokens.surfaceDark : GlassTokens.surfaceLight,
        shadow: false,
        onTap: onTap,
        child: Icon(
          icon,
          color: fg,
          size: 20,
        ),
      );
    }

    // ✅ heart pill
    Widget heartPill(TranscriptEntity t) {
      return LiquidGlass(
        borderRadius: BorderRadius.circular(999),
        padding: const EdgeInsets.all(8),
        backgroundColor:
            isDark ? GlassTokens.surfaceDark : GlassTokens.surfaceLight,
        shadow: false,
        onTap: () => _toggleFavourite(t),
        child: const Icon(
          Icons.favorite,
          color: Colors.redAccent,
          size: 18,
        ),
      );
    }

    return Scaffold(
      backgroundColor: GlassTokens.backgroundColor(context),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _unfocus,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text('Favourites', style: titleStyle),
                              if (showBusy) ...[
                                const SizedBox(width: 10),
                                SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(fg),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text('Your starred transcripts', style: subStyle),
                        ],
                      ),
                    ),
                    headerPill(icon: Icons.sort, onTap: _showSortSheet),
                  ],
                ),

                const SizedBox(height: 12),

                // List panel (glass)
                Expanded(
                  child: _items.isEmpty
                      ? const EmptyState(
                          title: 'No favourites yet',
                          subtitle:
                              'Tap the heart on any transcript to add it here.',
                          icon: Icons.favorite_border,
                        )
                      : GlassCard(
                          variant: GlassCardVariant.tile,
                          padding: EdgeInsets.zero,
                          child: ListView.separated(
                            controller: _ctrl,
                            physics: const BouncingScrollPhysics(),
                            addRepaintBoundaries: false,
                            addAutomaticKeepAlives: false,
                            itemCount: _items.length,
                            separatorBuilder: (_, _) =>
                                const GlassDivider(height: 1),
                            itemBuilder: (ctx, i) {
                              final t = _items[i];
                              final title = _displayTitle(t);

                              final isYoutube = (t.sourceType) == 1;
                              final isAudio = (t.sourceType) == 2;
                              final isVideo = (t.sourceType) == 3;

                              final sub = (isYoutube || isAudio || isVideo)
                                  ? _fmtDate(t.createdAt)
                                  : '${_fmtDate(t.createdAt)} • ${_fmtDuration(t.durationSec)}';

                              final leadingIcon = isYoutube
                                  ? Icons.subtitles
                                  : (isAudio
                                        ? Icons.audio_file
                                        : (isVideo
                                              ? Icons.video_file
                                              : Icons.article_outlined));

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
                                          color: fg,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    if (isYoutube || isAudio || isVideo) ...[
                                      const SizedBox(width: 8),
                                      if (isYoutube)
                                        const SourceTag(type: 'youtube')
                                      else if (isAudio)
                                        const SourceTag(type: 'audio')
                                      else if (isVideo)
                                        const SourceTag(type: 'video'),
                                    ],
                                  ],
                                ),
                                subtitle: Text(
                                  sub,
                                  style: TextStyle(
                                    color: muted,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                trailing: heartPill(t),
                                onTap: () => _openTranscript(t),
                              );
                            },
                          ),
                        ),
                ),

                const SizedBox(height: 20), // space for bottom dock
              ],
            ),
          ),
        ),
      ),
    );
  }
}
