import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../objectbox/entities.dart';
import '../objectbox/objectbox_store.dart';
import '../objectbox.g.dart';

import '../common/app_flushbar.dart';
import '../common/confirm_dialog.dart';
import '../transcript/transcript_detail_page.dart';
import '../transcript/youtube_saved_detail_page.dart';

// ✅ Glass primitives
import '../ui/glass/glass_tokens.dart';

enum _TranscriptSort {
  dateDesc,
  dateAsc,
  titleAsc,
  titleDesc,
  durationDesc,
  durationAsc,
}

enum _SourceFilter {
  all,
  voice,
  youtube,
  audio,
  video,
}

class FavouritesTab extends StatefulWidget {
  const FavouritesTab({super.key});

  @override
  State<FavouritesTab> createState() => _FavouritesTabState();
}

class _FavouritesTabState extends State<FavouritesTab> {
  final ScrollController _scrollCtrl = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  List<TranscriptEntity> _allFavourites = [];
  List<TranscriptEntity> _filteredItems = [];
  bool _loading = false;

  _TranscriptSort _sort = _TranscriptSort.dateDesc;
  _SourceFilter _sourceFilter = _SourceFilter.all;
  String _searchQuery = '';
  bool _showSearchBar = false;

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
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
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

  String _getSnippet(TranscriptEntity t) {
    final raw = (t.editedText?.trim().isNotEmpty ?? false)
        ? t.editedText!.trim()
        : ((t.fullTextCache?.trim().isNotEmpty ?? false)
            ? t.fullTextCache!.trim()
            : ((t.searchText?.trim().isNotEmpty ?? false)
                ? t.searchText!.trim()
                : (t.rawText?.trim() ?? '')));

    if (raw.isEmpty) return '';
    final singleLine = raw.replaceAll(RegExp(r'\s+'), ' ');
    return singleLine;
  }

  int _cmpTitle(TranscriptEntity a, TranscriptEntity b) {
    final ta = _displayTitle(a).toLowerCase();
    final tb = _displayTitle(b).toLowerCase();
    return ta.compareTo(tb);
  }

  void _applyFilterAndSort() {
    List<TranscriptEntity> list = List.from(_allFavourites);

    // 1. Source filter
    if (_sourceFilter != _SourceFilter.all) {
      list = list.where((t) {
        final st = t.sourceType;
        switch (_sourceFilter) {
          case _SourceFilter.voice:
            return st == 0;
          case _SourceFilter.youtube:
            return st == 1;
          case _SourceFilter.audio:
            return st == 2;
          case _SourceFilter.video:
            return st == 3;
          case _SourceFilter.all:
            return true;
        }
      }).toList();
    }

    // 2. Search query filter
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((t) {
        final title = _displayTitle(t).toLowerCase();
        final text = (t.searchText ?? t.fullTextCache ?? t.rawText ?? '')
            .toLowerCase();
        return title.contains(q) || text.contains(q);
      }).toList();
    }

    // 3. Sorting
    switch (_sort) {
      case _TranscriptSort.dateDesc:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        break;
      case _TranscriptSort.dateAsc:
        list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        break;
      case _TranscriptSort.titleAsc:
        list.sort(_cmpTitle);
        break;
      case _TranscriptSort.titleDesc:
        list.sort((a, b) => _cmpTitle(b, a));
        break;
      case _TranscriptSort.durationDesc:
        list.sort((a, b) => b.durationSec.compareTo(a.durationSec));
        break;
      case _TranscriptSort.durationAsc:
        list.sort((a, b) => a.durationSec.compareTo(b.durationSec));
        break;
    }

    _filteredItems = list;
  }

  // -----------------------
  // Data Load
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
        )..order(TranscriptEntity_.createdAt, flags: Order.descending);

        q = qb.build();
        _allFavourites = q.find();
        _applyFilterAndSort();
      } finally {
        q?.close();
      }
    } finally {
      _ss(() => _loading = false);
    }
  }

  // -----------------------
  // Favourite Toggle
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
      if (!newVal) {
        _allFavourites.removeWhere((x) => x.id == t.id);
        _applyFilterAndSort();
      }
    });

    HapticFeedback.lightImpact();

    if (!newVal && mounted) {
      await AppFlushbar.info(
        context,
        message: 'Removed from Favorites',
      );
    }
  }

  // -----------------------
  // Delete / Trash
  // -----------------------

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

  // -----------------------
  // Copy Content
  // -----------------------

  Future<void> _copyContent(TranscriptEntity t) async {
    final content = _getSnippet(t);
    final title = _displayTitle(t);
    final textToCopy = content.isNotEmpty ? '$title\n\n$content' : title;

    await Clipboard.setData(ClipboardData(text: textToCopy));
    if (!mounted || _disposed) return;
    await AppFlushbar.success(context, message: 'Copied to clipboard');
  }

  // -----------------------
  // Open Transcript
  // -----------------------

  Future<void> _openTranscript(TranscriptEntity t) async {
    _unfocus();

    final isYoutube = t.sourceType == 1;
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
  // Sort Bottom Sheet
  // -----------------------

  Future<void> _showSortSheet() async {
    if (!mounted || _disposed) return;
    _unfocus();

    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    final picked = await showModalBottomSheet<_TranscriptSort>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF191922) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        Widget sortTile({
          required _TranscriptSort value,
          required String title,
          required String subtitle,
          required IconData icon,
        }) {
          final isSelected = _sort == value;
          return InkWell(
            onTap: () => Navigator.of(ctx).pop(value),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 2.5),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: isSelected
                    ? (isDark
                        ? const Color(0xFF1E2A3A)
                        : const Color(0xFFE8F1FF))
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                border: isSelected
                    ? Border.all(
                        color: const Color(0xFF007AFF).withValues(alpha: 0.35),
                        width: 1,
                      )
                    : null,
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF007AFF)
                          : (isDark
                              ? const Color(0xFF242432)
                              : const Color(0xFFF0F1F6)),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(
                      icon,
                      size: 17,
                      color: isSelected ? Colors.white : muted,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: isSelected
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: isSelected ? const Color(0xFF007AFF) : fg,
                          ),
                        ),
                        const SizedBox(height: 1.5),
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isSelected)
                    const Icon(
                      Icons.check_circle_rounded,
                      color: Color(0xFF007AFF),
                      size: 19,
                    ),
                ],
              ),
            ),
          );
        }

        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.85,
            ),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 38,
                      height: 4.5,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(99),
                        color: isDark
                          ? Colors.white.withValues(alpha: 0.18)
                          : Colors.black.withValues(alpha: 0.15),
                      ),
                    ),
                  ),
                  Text(
                    'Sort Favorites',
                    style: TextStyle(
                      fontSize: 17.5,
                      fontWeight: FontWeight.w800,
                      color: fg,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 10),
                  sortTile(
                    value: _TranscriptSort.dateDesc,
                    title: 'Date: Newest First',
                    subtitle: 'Recently added or created items',
                    icon: Icons.schedule_rounded,
                  ),
                  sortTile(
                    value: _TranscriptSort.dateAsc,
                    title: 'Date: Oldest First',
                    subtitle: 'Chronological order from the start',
                    icon: Icons.history_rounded,
                  ),
                  sortTile(
                    value: _TranscriptSort.titleAsc,
                    title: 'Title: A → Z',
                    subtitle: 'Alphabetical order',
                    icon: Icons.sort_by_alpha_rounded,
                  ),
                  sortTile(
                    value: _TranscriptSort.titleDesc,
                    title: 'Title: Z → A',
                    subtitle: 'Reverse alphabetical order',
                    icon: Icons.sort_by_alpha_rounded,
                  ),
                  sortTile(
                    value: _TranscriptSort.durationDesc,
                    title: 'Duration: Longest First',
                    subtitle: 'Highest recording length',
                    icon: Icons.timelapse_rounded,
                  ),
                  sortTile(
                    value: _TranscriptSort.durationAsc,
                    title: 'Duration: Shortest First',
                    subtitle: 'Quick and short recordings',
                    icon: Icons.timer_outlined,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (picked == null) return;
    _ss(() {
      _sort = picked;
      _applyFilterAndSort();
    });
  }

  // -----------------------
  // Source Counts
  // -----------------------

  int _countForFilter(_SourceFilter f) {
    if (f == _SourceFilter.all) return _allFavourites.length;
    return _allFavourites.where((t) {
      final st = t.sourceType;
      switch (f) {
        case _SourceFilter.voice:
          return st == 0;
        case _SourceFilter.youtube:
          return st == 1;
        case _SourceFilter.audio:
          return st == 2;
        case _SourceFilter.video:
          return st == 3;
        case _SourceFilter.all:
          return true;
      }
    }).length;
  }

  // -----------------------
  // UI Builders
  // -----------------------

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);
    final isDark = GlassTokens.isDark(context);

    final totalFavCount = _allFavourites.length;

    return Scaffold(
      backgroundColor: GlassTokens.backgroundColor(context),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _unfocus,
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: _load,
            color: const Color(0xFF007AFF),
            child: CustomScrollView(
              controller: _scrollCtrl,
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              slivers: [
                // Top Header Section
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Row 1: Title + Count pill + Action buttons
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Text(
                                    'Favorites',
                                    style: TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w800,
                                      color: fg,
                                      letterSpacing: -0.4,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFF2D55)
                                          .withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: const Color(0xFFFF2D55)
                                            .withValues(alpha: 0.25),
                                        width: 1,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.favorite_rounded,
                                          size: 12,
                                          color: Color(0xFFFF2D55),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          '$totalFavCount',
                                          style: const TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w800,
                                            color: Color(0xFFFF2D55),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Search toggle
                                _IconButtonPill(
                                  icon: _showSearchBar
                                      ? Icons.search_off_rounded
                                      : Icons.search_rounded,
                                  isActive: _showSearchBar ||
                                      _searchQuery.isNotEmpty,
                                  tooltip: _showSearchBar
                                      ? 'Hide Search'
                                      : 'Search Favorites',
                                  onTap: () {
                                    _ss(() {
                                      _showSearchBar = !_showSearchBar;
                                      if (!_showSearchBar) {
                                        _searchCtrl.clear();
                                        _searchQuery = '';
                                        _applyFilterAndSort();
                                        _unfocus();
                                      } else {
                                        _searchFocus.requestFocus();
                                      }
                                    });
                                  },
                                ),
                                const SizedBox(width: 6),
                                // Sort button
                                _AnimatedSortButton(
                                  onTap: _showSortSheet,
                                ),
                                const SizedBox(width: 6),
                                // Reload button
                                _AnimatedReloadButton(
                                  loading: _loading,
                                  onTap: _loading ? null : _load,
                                ),
                              ],
                            ),
                          ],
                        ),

                        // Subtitle
                        const SizedBox(height: 2),
                        Text(
                          'Your starred transcripts & recordings',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: muted,
                          ),
                        ),

                        // Search Bar (expandable)
                        AnimatedCrossFade(
                          duration: const Duration(milliseconds: 220),
                          crossFadeState: _showSearchBar
                              ? CrossFadeState.showSecond
                              : CrossFadeState.showFirst,
                          firstChild: const SizedBox(height: 10),
                          secondChild: Padding(
                            padding: const EdgeInsets.only(top: 14, bottom: 4),
                            child: Container(
                              height: 44,
                              decoration: BoxDecoration(
                                color: isDark
                                    ? const Color(0xFF191922)
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isDark
                                      ? const Color(0xFF282834)
                                      : const Color(0xFFE2E4EB),
                                  width: 1,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: isDark
                                        ? Colors.black.withValues(alpha: 0.2)
                                        : Colors.black.withValues(alpha: 0.03),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: TextField(
                                controller: _searchCtrl,
                                focusNode: _searchFocus,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: fg,
                                  fontWeight: FontWeight.w600,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'Search in favorites...',
                                  hintStyle: TextStyle(
                                    fontSize: 13.5,
                                    color: muted,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  prefixIcon: Icon(
                                    Icons.search_rounded,
                                    size: 20,
                                    color: muted,
                                  ),
                                  suffixIcon: _searchCtrl.text.isNotEmpty
                                      ? IconButton(
                                          icon: Icon(
                                            Icons.clear_rounded,
                                            size: 18,
                                            color: muted,
                                          ),
                                          onPressed: () {
                                            _searchCtrl.clear();
                                            _ss(() {
                                              _searchQuery = '';
                                              _applyFilterAndSort();
                                            });
                                          },
                                        )
                                      : null,
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                                onChanged: (val) {
                                  _ss(() {
                                    _searchQuery = val.trim();
                                    _applyFilterAndSort();
                                  });
                                },
                              ),
                            ),
                          ),
                        ),

                        // Source Filter Chips
                        if (_allFavourites.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            clipBehavior: Clip.none,
                            child: Row(
                              children: [
                                _buildFilterChip(
                                  filter: _SourceFilter.all,
                                  label: 'All',
                                  icon: Icons.auto_awesome_rounded,
                                ),
                                const SizedBox(width: 8),
                                _buildFilterChip(
                                  filter: _SourceFilter.voice,
                                  label: 'Voice',
                                  icon: Icons.mic_rounded,
                                  accentColor: const Color(0xFF007AFF),
                                ),
                                const SizedBox(width: 8),
                                _buildFilterChip(
                                  filter: _SourceFilter.youtube,
                                  label: 'YouTube',
                                  icon: Icons.smart_display_rounded,
                                  accentColor: const Color(0xFFFF3B30),
                                ),
                                const SizedBox(width: 8),
                                _buildFilterChip(
                                  filter: _SourceFilter.audio,
                                  label: 'Audio',
                                  icon: Icons.audio_file_rounded,
                                  accentColor: const Color(0xFF00B0FF),
                                ),
                                const SizedBox(width: 8),
                                _buildFilterChip(
                                  filter: _SourceFilter.video,
                                  label: 'Video',
                                  icon: Icons.video_file_rounded,
                                  accentColor: const Color(0xFF635BFF),
                                ),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),

                // Main Content List or Empty State
                if (_allFavourites.isEmpty)
                  SliverToBoxAdapter(
                    child: _buildEmptyFavoritesState(isDark, fg, muted),
                  )
                else if (_filteredItems.isEmpty)
                  SliverToBoxAdapter(
                    child: _buildNoResultsState(isDark, fg, muted),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final item = _filteredItems[index];
                          return _FavoriteTranscriptCard(
                            key: ValueKey(item.id),
                            transcript: item,
                            snippet: _getSnippet(item),
                            onTap: () => _openTranscript(item),
                            onToggleFavourite: () => _toggleFavourite(item),
                            onDelete: () => _onDeletePressed(item),
                            onCopy: () => _copyContent(item),
                          );
                        },
                        childCount: _filteredItems.length,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChip({
    required _SourceFilter filter,
    required String label,
    required IconData icon,
    Color accentColor = const Color(0xFF007AFF),
  }) {
    final isSelected = _sourceFilter == filter;
    final count = _countForFilter(filter);
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        _ss(() {
          _sourceFilter = filter;
          _applyFilterAndSort();
        });
      },
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark
                  ? accentColor.withValues(alpha: 0.22)
                  : accentColor.withValues(alpha: 0.12))
              : (isDark
                  ? const Color(0xFF191922)
                  : const Color(0xFFF0F1F6)),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected
                ? accentColor.withValues(alpha: 0.5)
                : (isDark
                    ? const Color(0xFF282834)
                    : const Color(0xFFE2E4EB)),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: isSelected ? accentColor : muted,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                color: isSelected ? accentColor : fg,
              ),
            ),
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: isSelected
                    ? accentColor.withValues(alpha: 0.25)
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.06)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: isSelected ? accentColor : muted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyFavoritesState(bool isDark, Color fg, Color muted) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xFFFF2D55).withValues(alpha: 0.15),
                    const Color(0xFFFF5252).withValues(alpha: 0.05),
                  ],
                ),
                border: Border.all(
                  color: const Color(0xFFFF2D55).withValues(alpha: 0.2),
                  width: 1.5,
                ),
              ),
              child: const Center(
                child: Icon(
                  Icons.favorite_rounded,
                  size: 42,
                  color: Color(0xFFFF2D55),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'No Favorites Yet',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                color: fg,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap the heart icon on any transcript to save it here for quick and easy access anytime.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: muted,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoResultsState(bool isDark, Color fg, Color muted) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isDark
                    ? const Color(0xFF1E202B)
                    : const Color(0xFFF0F2F8),
              ),
              child: Icon(
                Icons.search_off_rounded,
                size: 36,
                color: muted,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'No Matching Favorites',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: fg,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _searchQuery.isNotEmpty
                  ? 'No favorites found matching "$_searchQuery"'
                  : 'No favorites found in this category',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: muted,
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () {
                _ss(() {
                  _searchCtrl.clear();
                  _searchQuery = '';
                  _sourceFilter = _SourceFilter.all;
                  _applyFilterAndSort();
                });
              },
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text(
                'Reset Filters',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF007AFF),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------
// REDESIGNED FAVORITE CARD
// -------------------------------------------------------------

class _FavoriteTranscriptCard extends StatelessWidget {
  const _FavoriteTranscriptCard({
    super.key,
    required this.transcript,
    required this.snippet,
    required this.onTap,
    required this.onToggleFavourite,
    required this.onDelete,
    required this.onCopy,
  });

  final TranscriptEntity transcript;
  final String snippet;
  final VoidCallback onTap;
  final VoidCallback onToggleFavourite;
  final VoidCallback onDelete;
  final VoidCallback onCopy;

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

    // Accent colors & icons per source
    Color accentColor = const Color(0xFF007AFF);
    IconData sourceIcon = Icons.mic_rounded;
    String sourceName = 'Voice';

    if (isYoutube) {
      accentColor = const Color(0xFFFF3B30);
      sourceIcon = Icons.smart_display_rounded;
      sourceName = 'YouTube';
    } else if (isAudio) {
      accentColor = const Color(0xFF00B0FF);
      sourceIcon = Icons.audio_file_rounded;
      sourceName = 'Audio';
    } else if (isVideo) {
      accentColor = const Color(0xFF635BFF);
      sourceIcon = Icons.video_file_rounded;
      sourceName = 'Video';
    }

    // Time & Date format
    final l = transcript.createdAt.toLocal();
    final now = DateTime.now();
    final isToday = l.year == now.year && l.month == now.month && l.day == now.day;
    final hour = l.hour == 0 ? 12 : (l.hour > 12 ? l.hour - 12 : l.hour);
    final min = l.minute.toString().padLeft(2, '0');
    final ampm = l.hour >= 12 ? 'PM' : 'AM';
    final timeStr = '$hour:$min $ampm';

    final dateStr = isToday
        ? 'Today • $timeStr'
        : '${_monthName(l.month)} ${l.day} • $timeStr';

    // Duration format
    final sec = transcript.durationSec.isFinite && transcript.durationSec >= 0
        ? transcript.durationSec.round()
        : 0;
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final ss = (sec % 60).toString().padLeft(2, '0');
    final durStr = h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';

    // Speakers count
    final speakerSet = transcript.turns.map((e) => e.speakerLabel).toSet();
    final speakerCount = speakerSet.isNotEmpty ? speakerSet.length : 1;

    // Subtitle string: e.g. "Today • 10:32 AM  •  12:34  •  2 Speakers"
    String typeStr;
    if (isYoutube) {
      typeStr = 'YouTube';
    } else if (isAudio) {
      typeStr = 'Audio File';
    } else if (isVideo) {
      typeStr = 'Video File';
    } else {
      typeStr = '$speakerCount Speaker${speakerCount == 1 ? '' : 's'}';
    }

    final subtitleStr = '$dateStr  •  $durStr  •  $typeStr';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF191922) : Colors.white,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: isDark ? const Color(0xFF282834) : const Color(0xFFEEF0F6),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: 0.18)
                : Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left Accent Color Bar
              Container(
                width: 4,
                color: accentColor,
              ),

              // Card Content Area
              Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onTap,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Row 1: Source Icon + Title + Heart Button + More Menu
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // Source Icon Badge
                              Container(
                                padding: const EdgeInsets.all(4.5),
                                decoration: BoxDecoration(
                                  color: accentColor.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(7),
                                ),
                                child: Icon(
                                  sourceIcon,
                                  size: 13.5,
                                  color: accentColor,
                                ),
                              ),
                              const SizedBox(width: 8),

                              // Title
                              Expanded(
                                child: Text(
                                  title,
                                  style: TextStyle(
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w700,
                                    color: fg,
                                    letterSpacing: -0.2,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 4),

                              // Quick Heart Toggle Button
                              _HeartButton(
                                isFavourite: transcript.isFavourite,
                                onTap: onToggleFavourite,
                              ),

                              // Contextual More Menu
                              PopupMenuButton<String>(
                                icon: Icon(
                                  Icons.more_vert_rounded,
                                  size: 18,
                                  color: muted,
                                ),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 140),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                onSelected: (val) {
                                  if (val == 'unfav') {
                                    onToggleFavourite();
                                  } else if (val == 'copy') {
                                    onCopy();
                                  } else if (val == 'delete') {
                                    onDelete();
                                  }
                                },
                                itemBuilder: (ctx) => [
                                  PopupMenuItem(
                                    value: 'unfav',
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.favorite_border_rounded,
                                          size: 17,
                                          color: Color(0xFFFF2D55),
                                        ),
                                        const SizedBox(width: 10),
                                        Text(
                                          'Unfavorite',
                                          style: TextStyle(
                                            fontSize: 13.5,
                                            color: fg,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'copy',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.copy_rounded,
                                          size: 17,
                                          color: fg,
                                        ),
                                        const SizedBox(width: 10),
                                        Text(
                                          'Copy Text',
                                          style: TextStyle(
                                            fontSize: 13.5,
                                            color: fg,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuDivider(height: 8),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.delete_outline_rounded,
                                          size: 17,
                                          color: Colors.redAccent,
                                        ),
                                        SizedBox(width: 10),
                                        Text(
                                          'Move to Trash',
                                          style: TextStyle(
                                            fontSize: 13.5,
                                            color: Colors.redAccent,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),

                          const SizedBox(height: 5),

                          // Row 2: Subtitle string + Source pill
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
                              const SizedBox(width: 6),

                              // Source Tag Pill
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: accentColor.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  sourceName,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: accentColor,
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _monthName(int m) {
    const months = [
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
    return (m >= 1 && m <= 12) ? months[m - 1] : '';
  }
}

// -------------------------------------------------------------
// MICRO-COMPONENTS (Animated Buttons & Icons)
// -------------------------------------------------------------

class _HeartButton extends StatefulWidget {
  const _HeartButton({
    required this.isFavourite,
    required this.onTap,
  });

  final bool isFavourite;
  final VoidCallback onTap;

  @override
  State<_HeartButton> createState() => _HeartButtonState();
}

class _HeartButtonState extends State<_HeartButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _scale = 0.75),
      onTapUp: (_) {
        setState(() => _scale = 1.0);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _scale = 1.0),
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutBack,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFFF2D55).withValues(alpha: 0.12),
          ),
          child: const Icon(
            Icons.favorite_rounded,
            size: 17,
            color: Color(0xFFFF2D55),
          ),
        ),
      ),
    );
  }
}

class _IconButtonPill extends StatelessWidget {
  const _IconButtonPill({
    required this.icon,
    required this.onTap,
    this.isActive = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool isActive;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final muted = GlassTokens.muted(context);

    Widget btn = InkWell(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: isActive
              ? (isDark
                  ? const Color(0xFF1E2A3A)
                  : const Color(0xFFE8F1FF))
              : (isDark
                  ? const Color(0xFF191922)
                  : const Color(0xFFF0F1F6)),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isActive
                ? const Color(0xFF007AFF).withValues(alpha: 0.4)
                : (isDark
                    ? const Color(0xFF282834)
                    : const Color(0xFFE2E4EB)),
            width: 1,
          ),
        ),
        child: Icon(
          icon,
          size: 19,
          color: isActive ? const Color(0xFF007AFF) : muted,
        ),
      ),
    );

    if (tooltip != null) {
      return Tooltip(message: tooltip!, child: btn);
    }
    return btn;
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
      duration: const Duration(milliseconds: 400),
    );

    _tiltAnim = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: -0.05)
            .chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 35,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: -0.05, end: 0.04)
            .chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 35,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.04, end: 0.0)
            .chain(CurveTween(curve: Curves.easeInOutCubic)),
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
    final isDark = GlassTokens.isDark(context);
    final muted = GlassTokens.muted(context);

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
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF191922)
                  : const Color(0xFFF0F1F6),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark
                    ? const Color(0xFF282834)
                    : const Color(0xFFE2E4EB),
                width: 1,
              ),
            ),
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                return RotationTransition(
                  turns: _tiltAnim,
                  child: Icon(
                    Icons.sort_rounded,
                    size: 19,
                    color: _controller.isAnimating
                        ? const Color(0xFF007AFF)
                        : muted,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _AnimatedReloadButton extends StatefulWidget {
  const _AnimatedReloadButton({
    required this.onTap,
    required this.loading,
  });

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
      duration: const Duration(milliseconds: 700),
    );

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
    final isDark = GlassTokens.isDark(context);
    final muted = GlassTokens.muted(context);

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
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF191922)
                  : const Color(0xFFF0F1F6),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark
                    ? const Color(0xFF282834)
                    : const Color(0xFFE2E4EB),
                width: 1,
              ),
            ),
            child: RotationTransition(
              turns: widget.loading ? _controller : _rotationAnim,
              child: Icon(
                Icons.refresh_rounded,
                size: 19,
                color: widget.loading ? const Color(0xFF007AFF) : muted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
