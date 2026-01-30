// lib/transcript/transcript_youtube_page.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_transcript_api/youtube_transcript_api.dart';

import '../common/app_flushbar.dart';

// ✅ adjust import paths to your project
import '../objectbox/objectbox_store.dart'; // ObjectBox.I
import '../objectbox/entities.dart'; // TranscriptEntity
import '../objectbox.g.dart'; // TranscriptEntity_ query props
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class TranscriptYoutubePage extends StatefulWidget {
  const TranscriptYoutubePage({super.key});

  @override
  State<TranscriptYoutubePage> createState() => _TranscriptYoutubePageState();
}

class _TranscriptYoutubePageState extends State<TranscriptYoutubePage> {
  static const String kRateLimitMsg =
      'YouTube rate-limited this network. Try again later or switch network.';

  final _ctrl = TextEditingController();

  bool _loading = false;
  bool _hasFetched = false;

  String? _videoId;

  List<_TranscriptItem> _manual = [];
  List<_TranscriptItem> _auto = [];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

  bool _isRateLimitError(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('too many requests') ||
        s.contains('rate limit') ||
        s.contains('receiving too many requests');
  }

  String _friendlyError(Object e) {
    if (_isRateLimitError(e)) return kRateLimitMsg;
    return 'Failed to load transcript.';
  }

  Future<String> _fetchOne(
    YouTubeTranscriptApi api,
    String videoId,
    String? languageCode,
  ) async {
    try {
      if (languageCode == null || languageCode.trim().isEmpty) {
        final tr = await api.fetch(videoId);
        return TextFormatter().format(tr).trim();
      }
      final tr = await api.fetch(videoId, languages: [languageCode]);
      return TextFormatter().format(tr).trim();
    } catch (e) {
      // ✅ friendly only
      return _friendlyError(e);
    }
  }

  Future<void> _fetchAll() async {
    _unfocus();

    final input = _ctrl.text.trim();
    final vid = _extractVideoId(input);

    if (vid == null || vid.isEmpty) {
      await AppFlushbar.success(context, message: 'Invalid YouTube link');
      return;
    }

    setState(() {
      _hasFetched = true;
      _loading = true;
      _videoId = vid;
      _manual = [];
      _auto = [];
    });

    final api = YouTubeTranscriptApi();

    // small delay between calls to reduce rate limiting
    Future<void> gap() => Future.delayed(const Duration(seconds: 1));

    try {
      // 1) list available transcript tracks
      final list = await api.list(vid);

      // Manual first, auto last (separate lists)
      final manualTracks = list.where((t) => t.isGenerated == false).toList();
      final autoTracks = list.where((t) => t.isGenerated == true).toList();

      final manualItems = <_TranscriptItem>[];
      final autoItems = <_TranscriptItem>[];

      bool rateLimited = false;

      // 2) fetch each manual track
      for (final t in manualTracks) {
        String text;

        if (rateLimited) {
          text = kRateLimitMsg; // don't hit YouTube again
        } else {
          text = await _fetchOne(api, vid, t.languageCode);
          if (text == kRateLimitMsg) rateLimited = true;
          await gap();
        }

        manualItems.add(
          _TranscriptItem(
            language: t.language,
            languageCode: t.languageCode,
            isGenerated: t.isGenerated,
            text: text,
          ),
        );
      }

      // 3) fetch each auto track
      for (final t in autoTracks) {
        String text;

        if (rateLimited) {
          text = kRateLimitMsg;
        } else {
          text = await _fetchOne(api, vid, t.languageCode);
          if (text == kRateLimitMsg) rateLimited = true;
          await gap();
        }

        autoItems.add(
          _TranscriptItem(
            language: t.language,
            languageCode: t.languageCode,
            isGenerated: t.isGenerated,
            text: text,
          ),
        );
      }

      if (!mounted) return;

      setState(() {
        _manual = manualItems;
        _auto = autoItems;
      });

      // ✅ SAVE (save friendly error strings too)
      final metaId = ObjectBox.I.saveYoutubeTranscripts(
        videoId: vid,
        inputUrl: input,
        manual: manualItems
            .map(
              (t) => YoutubeTranscriptTextPayload(
                language: t.language,
                languageCode: t.languageCode,
                isGenerated: t.isGenerated,
                text: t.text,
              ),
            )
            .toList(),
        auto: autoItems
            .map(
              (t) => YoutubeTranscriptTextPayload(
                language: t.language,
                languageCode: t.languageCode,
                isGenerated: t.isGenerated,
                text: t.text,
              ),
            )
            .toList(),
      );

      // ✅ Create/update TranscriptEntity list-row (sourceType=1)
      _upsertYoutubeTranscriptRow(metaId: metaId, videoId: vid);

      if (rateLimited) {
        await AppFlushbar.success(context, message: kRateLimitMsg);
      } else if (_manual.isEmpty && _auto.isEmpty) {
        await AppFlushbar.success(context, message: 'No transcripts found');
      } else {
        await AppFlushbar.success(context, message: 'Saved transcripts');
      }
    } catch (e) {
      if (!mounted) return;

      // ✅ show friendly toast if rate-limited, else generic
      final msg = _isRateLimitError(e) ? kRateLimitMsg : 'Failed to fetch.';
      await AppFlushbar.success(context, message: msg);

      // Also save a meta row + TranscriptEntity row even if list() fails?
      // (optional) — current behavior: only saves if list() succeeded.
    } finally {
      api.dispose();
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _upsertYoutubeTranscriptRow({
    required int metaId,
    required String videoId,
  }) {
    ObjectBox.I.store.runInTransaction(TxMode.write, () {
      // Find existing TranscriptEntity row by youtubeMetaId
      final qb = ObjectBox.I.transcripts.query(
        TranscriptEntity_.youtubeMetaId.equals(metaId),
      );
      final q = qb.build();
      final existing = q.findFirst();
      q.close();

      final now = DateTime.now();

      if (existing != null) {
        existing
          ..sourceType = 1
          ..youtubeMetaId = metaId
          ..title = (existing.title?.trim().isNotEmpty ?? false)
              ? existing.title!.trim()
              : 'YouTube: $videoId'
          ..model = 'youtube'
          ..lang = 'multi'
          ..durationSec = 0
          ..updatedAt = now;

        ObjectBox.I.transcripts.put(existing);
        return;
      }

      // Create new TranscriptEntity list-row
      final e = TranscriptEntity(
        title: 'YouTube: $videoId',
        model: 'youtube',
        lang: 'multi',
        durationSec: 0,
        sourceType: 1,
        youtubeMetaId: metaId,
        createdAt: now,
        updatedAt: now,
      );

      ObjectBox.I.transcripts.put(e);
    });
  }

  String _canonicalYoutubeUrl(String input, String? videoId) {
    if (input.trim().isNotEmpty) return input.trim();
    if (videoId != null && videoId.isNotEmpty) {
      return 'https://www.youtube.com/watch?v=$videoId';
    }
    return '';
  }

  String _buildTxtExport({
    required String url,
    required List<_TranscriptItem> manual,
    required List<_TranscriptItem> auto,
  }) {
    final b = StringBuffer();

    b.writeln('Video URL: $url');
    b.writeln();

    void writeSection(String title, List<_TranscriptItem> items) {
      if (items.isEmpty) return;
      b.writeln('===== $title =====');
      b.writeln();

      for (final it in items) {
        final langName = (it.language?.trim().isNotEmpty ?? false)
            ? it.language!.trim()
            : 'Unknown';
        final code = (it.languageCode?.trim().isNotEmpty ?? false)
            ? it.languageCode!.trim()
            : '--';

        b.writeln('[$langName] ($code)');
        b.writeln(
          it.text.trim().isEmpty ? '(empty transcript)' : it.text.trim(),
        );
        b.writeln();
      }
    }

    writeSection('MANUAL', manual);
    writeSection('AUTO-GENERATED', auto);

    return b.toString().trim();
  }

  Future<void> _shareAllAsTxt() async {
    if (_videoId == null || !_hasFetched) {
      await AppFlushbar.success(context, message: 'Nothing to share yet');
      return;
    }

    final url = _canonicalYoutubeUrl(_ctrl.text, _videoId);
    final content = _buildTxtExport(url: url, manual: _manual, auto: _auto);

    try {
      final dir = await getTemporaryDirectory();
      final safeId = (_videoId ?? 'youtube').replaceAll(
        RegExp(r'[^a-zA-Z0-9_-]'),
        '',
      );
      final out = File('${dir.path}/youtube_transcript_$safeId.txt');

      await out.writeAsString(content, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(
              out.path,
              mimeType: 'text/plain',
              name: out.uri.pathSegments.last,
            ),
          ],
          subject: 'YouTube transcript ($safeId)',
          text: 'Video: $url',
        ),
      );
    } catch (_) {
      if (!mounted) return;
      await AppFlushbar.success(context, message: 'Failed to share file');
    }
  }

  String? _extractVideoId(String input) {
    // Accept plain ID
    final plain = RegExp(r'^[a-zA-Z0-9_-]{11}$');
    if (plain.hasMatch(input)) return input;

    final patterns = <RegExp>[
      RegExp(r'(?:v=)([a-zA-Z0-9_-]{11})'),
      RegExp(r'(?:youtu\.be/)([a-zA-Z0-9_-]{11})'),
      RegExp(r'(?:shorts/)([a-zA-Z0-9_-]{11})'),
      RegExp(r'(?:embed/)([a-zA-Z0-9_-]{11})'),
    ];

    for (final p in patterns) {
      final m = p.firstMatch(input);
      if (m != null && m.groupCount >= 1) return m.group(1);
    }
    return null;
  }

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

    final chipBorder = isDark
        ? Colors.white.withOpacity(0.10)
        : Colors.black.withOpacity(0.08);
    final chipBg = isDark
        ? Colors.white.withOpacity(0.06)
        : Colors.black.withOpacity(0.04);

    final manualSubtitle = !_hasFetched
        ? 'Not fetched yet'
        : (_manual.isEmpty ? 'None' : '${_manual.length} available');

    final autoSubtitle = !_hasFetched
        ? 'Not fetched yet'
        : (_auto.isEmpty ? 'None' : '${_auto.length} available');

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text('YouTube Transcripts'),
        actions: [
          // ✅ Share as .txt (only enabled after fetch)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: _IconPillButton(
              tooltip: 'Share .txt',
              icon: Icons.ios_share,
              onTap:
                  (_hasFetched &&
                      !_loading &&
                      (_manual.isNotEmpty || _auto.isNotEmpty))
                  ? _shareAllAsTxt
                  : null,
            ),
          ),

          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: _IconPillButton(
              tooltip: 'Close',
              icon: Icons.close,
              onTap: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _unfocus,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            children: [
              // Input panel
              Container(
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
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Paste a YouTube link',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _ctrl,
                      cursorColor: Colors.white,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _loading ? null : _fetchAll(),
                      decoration: InputDecoration(
                        hintText: 'https://www.youtube.com/watch?v=...',
                        filled: true,
                        fillColor: chipBg,
                        hintStyle: TextStyle(color: Colors.white24),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: chipBorder),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: chipBorder),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _loading ? null : _fetchAll,
                            icon: _loading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.subtitles,color: Colors.white,),
                            label: Text(
                              _loading ? 'Getting…' : 'Get transcripts',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_videoId != null) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _MiniPill(
                            label: 'Video ID: $_videoId',
                            isDark: isDark,
                          ),
                          _MiniPill(
                            label: 'Manual: ${_manual.length}',
                            isDark: isDark,
                          ),
                          _MiniPill(
                            label: 'Auto: ${_auto.length}',
                            isDark: isDark,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // Manual
              _SectionHeader(
                title: 'Manual transcripts',
                subtitle: manualSubtitle,
              ),
              const SizedBox(height: 10),
              _manual.isEmpty
                  ? (_hasFetched
                        ? const _EmptySmall(
                            text: 'No manual transcripts for this video.',
                          )
                        : const _EmptySmall(
                            text:
                                'Paste a link above, then tap “Get transcripts”.',
                          ))
                  : _TranscriptList(items: _manual),

              const SizedBox(height: 16),

              // Auto
              _SectionHeader(
                title: 'Auto-generated transcripts',
                subtitle: autoSubtitle,
              ),
              const SizedBox(height: 10),
              _auto.isEmpty
                  ? (_hasFetched
                        ? const _EmptySmall(
                            text:
                                'No auto-generated transcripts for this video.',
                          )
                        : const _EmptySmall(
                            text:
                                'Auto transcripts will appear here after fetching.',
                          ))
                  : _TranscriptList(items: _auto),

              const SizedBox(height: 72),
            ],
          ),
        ),
      ),
    );
  }
}

class _TranscriptItem {
  final String? language;
  final String? languageCode;
  final bool isGenerated;
  final String text;

  _TranscriptItem({
    required this.language,
    required this.languageCode,
    required this.isGenerated,
    required this.text,
  });
}

class _TranscriptList extends StatelessWidget {
  const _TranscriptList({required this.items});
  final List<_TranscriptItem> items;

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

    return Container(
      decoration: BoxDecoration(
        color: panelBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: panelBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        itemCount: items.length,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        separatorBuilder: (_, __) => const Divider(height: 1, thickness: 0.6),
        itemBuilder: (ctx, i) => _TranscriptCard(item: items[i]),
      ),
    );
  }
}

class _TranscriptCard extends StatelessWidget {
  const _TranscriptCard({required this.item});
  final _TranscriptItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final border = isDark
        ? Colors.white.withOpacity(0.10)
        : Colors.black.withOpacity(0.08);
    final bg = isDark
        ? Colors.white.withOpacity(0.06)
        : Colors.black.withOpacity(0.04);

    final langName = (item.language?.trim().isNotEmpty ?? false)
        ? item.language!.trim()
        : 'Unknown';
    final code = (item.languageCode?.trim().isNotEmpty ?? false)
        ? item.languageCode!.trim()
        : '--';
    final langLabel = '$langName  [$code]';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // header row
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.language, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          langLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton(
                tooltip: 'Copy',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: item.text));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied transcript')),
                    );
                  }
                },
                icon: const Icon(Icons.copy),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // transcript text
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: border),
            ),
            child: _ExpandableTranscriptBox(
              text: item.text,
              previewLines: 6,
              bg: bg,
              border: border,
              textStyle: theme.textTheme.bodySmall?.copyWith(
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: isDark
                    ? Colors.white.withOpacity(0.92)
                    : Colors.black.withOpacity(0.82),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: isDark ? Colors.white70 : Colors.black54,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniPill extends StatelessWidget {
  const _MiniPill({required this.label, required this.isDark});
  final String label;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final border = isDark
        ? Colors.white.withOpacity(0.10)
        : Colors.black.withOpacity(0.08);
    final bg = isDark
        ? Colors.white.withOpacity(0.06)
        : Colors.black.withOpacity(0.04);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _EmptySmall extends StatelessWidget {
  const _EmptySmall({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 4),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: isDark ? Colors.white70 : Colors.black54,
          fontWeight: FontWeight.w600,
        ),
      ),
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
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final border = (isDark ? Colors.white : Colors.black).withOpacity(0.10);
    final bg = (isDark ? Colors.white : Colors.black).withOpacity(0.06);

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: bg,
          border: Border.all(color: border),
        ),
        child: Tooltip(
          message: tooltip,
          child: Icon(
            icon,
            color: onTap == null
                ? (isDark ? Colors.white38 : Colors.black38)
                : null,
          ),
        ),
      ),
    );
  }
}

class _ExpandableTranscriptBox extends StatefulWidget {
  const _ExpandableTranscriptBox({
    required this.text,
    required this.bg,
    required this.border,
    required this.textStyle,
    this.previewLines = 6,
    super.key,
  });

  final String text;
  final Color bg;
  final Color border;
  final TextStyle? textStyle;
  final int previewLines;

  @override
  State<_ExpandableTranscriptBox> createState() =>
      _ExpandableTranscriptBoxState();
}

class _ExpandableTranscriptBoxState extends State<_ExpandableTranscriptBox>
    with TickerProviderStateMixin {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final t = widget.text.trim().isEmpty ? '(empty transcript)' : widget.text;
    final controlColor = isDark ? Colors.white70 : Colors.black54;

    Widget buildBox({required bool expanded}) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: widget.bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: widget.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t,
              maxLines: expanded ? null : widget.previewLines,
              overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
              style: widget.textStyle,
            ),
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: controlColor,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      expanded ? 'Show less' : 'Show more',
                      style: TextStyle(
                        color: controlColor,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    // ✅ This makes the whole “card box” collapse/expand, not just the Text.
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: ClipRect(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeOut,
          child: KeyedSubtree(
            key: ValueKey(_expanded),
            child: buildBox(expanded: _expanded),
          ),
        ),
      ),
    );
  }
}
