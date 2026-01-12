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
            .or(TranscriptEntity_.searchText.contains(qText, caseSensitive: false)),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _unfocus,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Column(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: theme.dividerColor.withOpacity(0.4)),
                  ),
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    autofocus: false, // ✅ no auto pop
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _unfocus(),
                    onChanged: _onChanged,
                    decoration: InputDecoration(
                      hintText: 'Search transcripts (title and content)',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: (_ctrl.text.trim().isEmpty)
                          ? null
                          : IconButton(
                              tooltip: 'Clear',
                              icon: const Icon(Icons.close),
                              onPressed: _clear,
                            ),
                      border: InputBorder.none,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                Expanded(
                  child: Card(
                    elevation: 0.6,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _q.isEmpty
                        ? ListView(
                            controller: _listCtrl,
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 28, 16, 28),
                                child: Center(
                                  child: Text(
                                    'Type something to search.\nResults will appear here.',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodyMedium
                                        ?.copyWith(color: Colors.white70),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : _loading
                            ? const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(16),
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            : _results.isEmpty
                                ? ListView(
                                    controller: _listCtrl,
                                    physics: const AlwaysScrollableScrollPhysics(),
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                            16, 28, 16, 28),
                                        child: Center(
                                          child: Text(
                                            'No results for “$_q”.',
                                            textAlign: TextAlign.center,
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(color: Colors.white70),
                                          ),
                                        ),
                                      ),
                                    ],
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
                                        title: Text(
                                          title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        subtitle: Text(sub),
                                        leading: const Icon(Icons.article_outlined),
                                        trailing: const Icon(Icons.chevron_right),
                                        onTap: () async {
                                          _unfocus();
                                          await Navigator.of(context).push(
                                            MaterialPageRoute(
                                              builder: (_) => TranscriptDetailPage(
                                                  transcriptId: t.id),
                                            ),
                                          );
                                          _unfocus();
                                        },
                                      );
                                    },
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
