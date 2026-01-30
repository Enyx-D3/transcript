import 'dart:async';

import 'package:flutter/material.dart';

import '../objectbox/entities.dart';
import '../objectbox/objectbox_store.dart';
import '../objectbox.g.dart';
import '../transcript/transcript_detail_page.dart';

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
        TranscriptEntity_.title
            .contains(qText, caseSensitive: false)
            .or(
              TranscriptEntity_.searchText.contains(
                qText,
                caseSensitive: false,
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
    if (_listCtrl.hasClients) {
      _listCtrl.jumpTo(0);
    }
  }

  // ---------- UI helpers ----------
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

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
                // ---------- Custom header ----------
                Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Search',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Find transcripts by title or content',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: isDark ? Colors.white70 : Colors.black54,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    if (_ctrl.text.trim().isNotEmpty)
                      _IconPillButton(
                        tooltip: 'Clear',
                        icon: Icons.close,
                        onTap: _clear,
                      ),
                  ],
                ),

                const SizedBox(height: 14),

                // ---------- Search box panel ----------
                Container(
                  decoration: _panelDecoration(context),
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Row(
                    children: [
                      const Icon(Icons.search),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          cursorColor: Colors.white,
                          controller: _ctrl,
                          focusNode: _focus,
                          autofocus: false,
                          textInputAction: TextInputAction.search,
                          onSubmitted: (_) => _unfocus(),
                          onChanged: _onChanged,
                          decoration: InputDecoration(
                            hintText: 'Search transcripts…',
                            hintStyle: TextStyle(
                              color: isDark ? Colors.white54 : Colors.black45,
                              fontWeight: FontWeight.w600,
                            ),
                            border: InputBorder.none,
                            isDense: true,
                          ),
                        ),
                      ),
                      if (_loading) ...[
                        const SizedBox(width: 10),
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ] else if (_ctrl.text.trim().isNotEmpty) ...[
                        const SizedBox(width: 6),
                        IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.close),
                          onPressed: _clear,
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // ---------- Results panel ----------
                Expanded(
                  child: _q.isEmpty
                      ? _EmptyState(
                          controller: _listCtrl,
                          text:
                              'Type something to search.\nResults will appear here.',
                        )
                      : _loading
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(18),
                            child: CircularProgressIndicator(),
                          ),
                        )
                      : _results.isEmpty
                      ? _EmptyState(
                          controller: _listCtrl,
                          text: 'No results for “$_q”.',
                        )
                      : ListView.separated(
                          controller: _listCtrl,
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: _results.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1, thickness: 0.6),
                          itemBuilder: (ctx, i) {
                            final t = _results[i];
                            final title = (t.title?.trim().isNotEmpty ?? false)
                                ? t.title!.trim()
                                : 'Untitled transcript';
                            final sub =
                                '${_fmtDate(t.createdAt)} • ${_fmtDuration(t.durationSec)}';

                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 4,
                              ),
                              leading: const _LeadingPillIcon(
                                icon: Icons.article_outlined,
                              ),
                              title: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(sub),
                              trailing: const Icon(Icons.chevron_right),
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

                const SizedBox(height: 72), // space for bottom dock
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.controller, required this.text});

  final ScrollController controller;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      controller: controller,
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 34, 16, 34),
          child: Center(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white70,
              ),
            ),
          ),
        ),
      ],
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
      child: Icon(icon, size: 20),
    );
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
