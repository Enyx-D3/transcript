// lib/tabs/search_tab.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:transcript/widgets/empty_state.dart';
import 'package:transcript/widgets/leading_pill_icon.dart';
import 'package:transcript/widgets/solid_section_toolbar.dart';

import '../objectbox/entities.dart';
import '../objectbox/objectbox_store.dart';
import '../objectbox.g.dart';
import '../transcript/transcript_detail_page.dart';

// ✅ Glass primitives
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';

class SearchTab extends StatefulWidget {
  const SearchTab({super.key});

  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  final ScrollController _listCtrl = ScrollController();

  Timer? _debounce;
  String _q = '';
  bool _loading = false;
  List<TranscriptEntity> _results = const [];

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    _listCtrl.dispose();
    super.dispose();
  }

  void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      if (!mounted) return;
      final next = v.trim();
      setState(() => _q = next);
      await _search(next);
    });
  }

  Future<void> _search(String qText) async {
    if (_loading) return;

    if (qText.isEmpty) {
      setState(() {
        _results = const [];
        _loading = false;
      });
      return;
    }

    setState(() => _loading = true);

    final box = ObjectBox.I.transcripts;

    Query<TranscriptEntity>? q;
    try {
      final qb = box.query(
        TranscriptEntity_.isDeleted
            .equals(false)
            .and(
              TranscriptEntity_.title
                  .contains(qText, caseSensitive: false)
                  .or(
                    TranscriptEntity_.searchText.contains(
                      qText,
                      caseSensitive: false,
                    ),
                  ),
            ),
      )..order(TranscriptEntity_.createdAt, flags: Order.descending);

      q = qb.build();
      final items = q.find();

      if (!mounted) return;
      setState(() => _results = items);
    } finally {
      q?.close();
      if (mounted) setState(() => _loading = false);
    }
  }

  void _clear() {
    _debounce?.cancel();
    _ctrl.clear();
    setState(() {
      _q = '';
      _results = const [];
    });
    _unfocus();
    if (_listCtrl.hasClients) _listCtrl.jumpTo(0);
  }

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

    Widget closePill({double iconSize = 18}) {
      return LiquidGlass(
        borderRadius: BorderRadius.circular(999),
        padding: const EdgeInsets.all(8),
        backgroundColor:
            isDark ? GlassTokens.surfaceDark : GlassTokens.surfaceLight,
        shadow: false,
        onTap: _clear,
        child: Icon(
          Icons.close,
          color: fg,
          size: iconSize,
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _unfocus,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ---------- Header ----------
                Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Search', style: titleStyle),
                        const SizedBox(height: 2),
                        Text(
                          'Find transcripts by title or content',
                          style: subStyle,
                        ),
                      ],
                    ),
                    const Spacer(),
                  ],
                ),

                const SizedBox(height: 14),

                // ---------- Search box ----------
                GlassCard(
                  variant: GlassCardVariant.panel,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Row(
                    children: [
                      Icon(
                        Icons.search,
                        color: fg,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          cursorColor: fg,
                          controller: _ctrl,
                          focusNode: _focus,
                          autofocus: false,
                          textInputAction: TextInputAction.search,
                          onSubmitted: (_) => _unfocus(),
                          onChanged: _onChanged,
                          style: TextStyle(
                            color: fg,
                            fontWeight: FontWeight.w600,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Search transcripts…',
                            hintStyle: TextStyle(
                              color: muted,
                              fontWeight: FontWeight.w600,
                            ),
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          contextMenuBuilder: (context, editableTextState) {
                            return SolidSelectionToolbar(
                              editableTextState: editableTextState,
                            );
                          },
                        ),
                      ),
                      if (_loading) ...[
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(fg),
                          ),
                        ),
                      ] else if (_ctrl.text.trim().isNotEmpty) ...[
                        const SizedBox(width: 6),
                        closePill(iconSize: 18),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // ---------- Results ----------
                Expanded(
                  child: _q.isEmpty
                      ? const EmptyState(
                          title: 'Type something to search.',
                          subtitle: '',
                          icon: Icons.search,
                        )
                      : _loading
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(18),
                            child: CircularProgressIndicator(),
                          ),
                        )
                      : _results.isEmpty
                      ? EmptyState(
                          title: 'No results for “$_q”.',
                          subtitle: '',
                          icon: Icons.search,
                        )
                      : GlassCard(
                          variant: GlassCardVariant.tile,
                          padding: EdgeInsets.zero,
                          child: ListView.separated(
                            controller: _listCtrl,
                            physics: const AlwaysScrollableScrollPhysics(),
                            addRepaintBoundaries: false,
                            addAutomaticKeepAlives: false,
                            itemCount: _results.length,
                            separatorBuilder: (_, _) =>
                                const GlassDivider(height: 1),
                            itemBuilder: (ctx, i) {
                              final t = _results[i];
                              final title =
                                  (t.title?.trim().isNotEmpty ?? false)
                                  ? t.title!.trim()
                                  : 'Untitled transcript';
                              final sub =
                                  '${_fmtDate(t.createdAt)} • ${_fmtDuration(t.durationSec)}';

                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 4,
                                ),
                                leading: const LeadingPillIcon(
                                  icon: Icons.article_outlined,
                                ),
                                title: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: fg,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                subtitle: Text(
                                  sub,
                                  style: TextStyle(
                                    color: muted,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                trailing: Icon(
                                  Icons.chevron_right,
                                  color: muted,
                                ),
                                onTap: () async {
                                  _unfocus();
                                  await Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => TranscriptDetailPage(
                                        transcriptId: t.id,
                                      ),
                                    ),
                                  );
                                  _unfocus();
                                },
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
