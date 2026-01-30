import 'package:flutter/material.dart';

import '../objectbox/entities.dart';
import '../objectbox/objectbox_store.dart';
import '../objectbox.g.dart';

import '../common/app_flushbar.dart';
import '../transcript/transcript_detail_page.dart';
import '../transcript/youtube_saved_detail_page.dart';

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
  // Helpers (same as Timeline)
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
  // Data load (favorites only)
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

        // for date sorts, let ObjectBox order by createdAt
        if (_sort == _TranscriptSort.dateAsc) {
          qb.order(TranscriptEntity_.createdAt, flags: 0);
        } else {
          qb.order(TranscriptEntity_.createdAt, flags: Order.descending);
        }

        q = qb.build();
        _items = q.find();

        // for title sorts, do in-memory
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
  // Sort sheet
  // -----------------------

  Future<void> _showSortSheet() async {
    if (!mounted || _disposed) return;

    final picked = await showModalBottomSheet<_TranscriptSort>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        Widget tile(
          _TranscriptSort v,
          String title,
          String subtitle,
          IconData ic,
        ) {
          final selected = _sort == v;
          return ListTile(
            leading: Icon(ic),
            title: Text(title),
            subtitle: Text(subtitle),
            trailing: selected ? const Icon(Icons.check) : null,
            onTap: () => Navigator.of(ctx).pop(v),
          );
        }

        return SafeArea(
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
        );
      },
    );

    if (picked == null) return;

    _ss(() => _sort = picked);
    await _load();
  }

  // -----------------------
  // Favourite toggle (instant remove when unfavourited)
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

    // ✅ If unfavourited inside Favourites, remove immediately from list
    _ss(() {
      t.isFavourite = newVal;
      if (!newVal) {
        _items.removeWhere((x) => x.id == t.id);
      }
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
    // Optional: refresh in case user changed fav in details page
    await _load();
  }

  // -----------------------
  // UI
  // -----------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final panelBg = isDark
        ? const Color(0xFF101018)
        : theme.colorScheme.surface;
    final panelBorder = isDark
        ? Colors.white.withOpacity(0.10)
        : Colors.black.withOpacity(0.08);

    return Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _unfocus,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ✅ fixed header
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Favourites',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Your starred transcripts',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isDark ? Colors.white70 : Colors.black54,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Sort',
                      onPressed: _showSortSheet,
                      icon: const Icon(Icons.sort),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                // ✅ scrollable list section
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: panelBg,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: panelBorder),
                      boxShadow: [
                        BoxShadow(
                          blurRadius: 18,
                          color: Colors.black.withOpacity(isDark ? 0.25 : 0.08),
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _items.isEmpty
                        ? _EmptyState(isDark: isDark)
                        : ListView.separated(
                            controller: _ctrl, // ✅ now used here
                            physics: const BouncingScrollPhysics(),
                            itemCount: _items.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1, thickness: 0.6),
                            itemBuilder: (ctx, i) {
                              final t = _items[i];
                              final title = _displayTitle(t);

                              final isYoutube = (t.sourceType) == 1;
                              final sub = isYoutube
                                  ? '${_fmtDate(t.createdAt)} • YouTube'
                                  : '${_fmtDate(t.createdAt)} • ${_fmtDuration(t.durationSec)}';

                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 4,
                                ),
                                leading: _LeadingPillIcon(
                                  icon: isYoutube
                                      ? Icons.subtitles
                                      : Icons.article_outlined,
                                ),
                                title: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (isYoutube) ...[
                                      const SizedBox(width: 8),
                                      const _SourceTagYoutube(),
                                    ],
                                  ],
                                ),
                                subtitle: Text(sub),
                                trailing: IconButton(
                                  tooltip: 'Unfavourite',
                                  icon: const Icon(
                                    Icons.favorite,
                                    color: Colors.red,
                                  ),
                                  onPressed: () => _toggleFavourite(t),
                                ),
                                onTap: () => _openTranscript(t),
                              );
                            },
                          ),
                  ),
                ),

                const SizedBox(height: 10), // space for bottom dock
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------- UI widgets reused (same look) ----------------

class _SourceTagYoutube extends StatelessWidget {
  const _SourceTagYoutube();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final border = Colors.red.withOpacity(isDark ? 0.45 : 0.35);
    final bg = Colors.red.withOpacity(isDark ? 0.16 : 0.10);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: const Text(
        'YOUTUBE',
        style: TextStyle(
          fontWeight: FontWeight.w900,
          letterSpacing: 0.3,
          color: Colors.red,
          fontSize: 6,
        ),
      ),
    );
  }
}

class _LeadingPillIcon extends StatelessWidget {
  const _LeadingPillIcon({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
      child: Icon(icon, size: 20),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.isDark});
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      child: Column(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: (isDark ? Colors.white : Colors.black).withOpacity(0.06),
              border: Border.all(
                color: (isDark ? Colors.white : Colors.black).withOpacity(0.10),
              ),
            ),
            child: const Icon(Icons.favorite_border, size: 26),
          ),
          const SizedBox(height: 10),
          Text(
            'No favourites yet',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Tap the heart on any transcript to add it here.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: isDark ? Colors.white70 : Colors.black54,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}
