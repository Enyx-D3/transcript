// lib/transcript/youtube_saved_detail_page.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:youtube_transcript_api/youtube_transcript_api.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';
import '../common/app_flushbar.dart';

class YoutubeSavedTranscriptPage extends StatefulWidget {
  const YoutubeSavedTranscriptPage({
    super.key,
    required this.transcriptId,
    required this.youtubeMetaId,
  });

  final int transcriptId; // TranscriptEntity row id
  final int youtubeMetaId;

  @override
  State<YoutubeSavedTranscriptPage> createState() =>
      _YoutubeSavedTranscriptPageState();
}

class _YoutubeSavedTranscriptPageState
    extends State<YoutubeSavedTranscriptPage> {
  static const String kRateLimitMsg =
      'YouTube rate-limited this network. Try again later or switch network.';

  bool _loading = true;
  bool _regenerating = false;

  YoutubeTranscriptMetaEntity? _meta;
  List<YoutubeTranscriptTextEntity> _manual = [];
  List<YoutubeTranscriptTextEntity> _auto = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

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

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);

    final meta = ObjectBox.I.ytMeta.get(widget.youtubeMetaId);

    if (meta == null) {
      if (mounted) {
        setState(() {
          _meta = null;
          _manual = [];
          _auto = [];
          _loading = false;
        });
      }
      return;
    }

    Query<YoutubeTranscriptTextEntity>? q;
    try {
      final qb = ObjectBox.I.ytTexts.query(
        YoutubeTranscriptTextEntity_.meta.equals(widget.youtubeMetaId),
      );
      q = qb.build();
      final all = q.find();

      final manual = <YoutubeTranscriptTextEntity>[];
      final auto = <YoutubeTranscriptTextEntity>[];

      for (final t in all) {
        if (t.isGenerated) {
          auto.add(t);
        } else {
          manual.add(t);
        }
      }

      if (!mounted) return;
      setState(() {
        _meta = meta;
        _manual = manual;
        _auto = auto;
      });
    } finally {
      q?.close();
      if (mounted) setState(() => _loading = false);
    }
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
      return _friendlyError(e);
    }
  }

  void _upsertYoutubeTranscriptRow({
    required int metaId,
    required String videoId,
  }) {
    ObjectBox.I.store.runInTransaction(TxMode.write, () {
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

  Future<void> _regenerate() async {
    final meta = _meta ?? ObjectBox.I.ytMeta.get(widget.youtubeMetaId);
    if (meta == null) {
      await AppFlushbar.success(context, message: 'Not found');
      return;
    }

    if (mounted) setState(() => _regenerating = true);

    final api = YouTubeTranscriptApi();
    Future<void> gap() => Future.delayed(const Duration(milliseconds: 400));

    bool rateLimited = false;

    try {
      final vid = meta.videoId;

      final list = await api.list(vid);
      final manualTracks = list.where((t) => t.isGenerated == false).toList();
      final autoTracks = list.where((t) => t.isGenerated == true).toList();

      final manualItems = <_TranscriptItem>[];
      final autoItems = <_TranscriptItem>[];

      for (final t in manualTracks) {
        String text;
        if (rateLimited) {
          text = kRateLimitMsg;
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

      final metaId = ObjectBox.I.saveYoutubeTranscripts(
        videoId: vid,
        inputUrl: meta.inputUrl,
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

      _upsertYoutubeTranscriptRow(metaId: metaId, videoId: vid);
      await _load();

      if (!mounted) return;

      await AppFlushbar.success(
        context,
        message: rateLimited ? kRateLimitMsg : 'Generated again & saved',
      );
    } catch (e) {
      if (!mounted) return;
      final msg = _isRateLimitError(e) ? kRateLimitMsg : 'Failed to generate.';
      await AppFlushbar.success(context, message: msg);
    } finally {
      api.dispose();
      if (mounted) setState(() => _regenerating = false);
    }
  }

  // -------------------------
  // ✅ SHARE (.txt)
  // -------------------------
  String _bestUrl(YoutubeTranscriptMetaEntity m) {
    final c = m.canonicalUrl.trim();
    return c.isNotEmpty ? c : m.inputUrl.trim();
  }

  String _safeFileId(String raw) {
    // keep filename safe
    return raw.replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_');
  }

  String _buildTxtExport() {
    final m = _meta!;
    final url = _bestUrl(m);

    final sb = StringBuffer();
    sb.writeln('Video url: $url');
    sb.writeln();

    void appendBlock(YoutubeTranscriptTextEntity t, {required bool isAuto}) {
      final langName = (t.language?.trim().isNotEmpty ?? false)
          ? t.language!.trim()
          : 'Unknown';
      final code = (t.languageCode?.trim().isNotEmpty ?? false)
          ? t.languageCode!.trim()
          : '--';

      final label = '$langName - $code';
      final mode = isAuto ? 'AUTO' : 'MANUAL';

      sb.writeln('[$label] ($mode)');
      sb.writeln(t.text.trim().isEmpty ? '(empty transcript)' : t.text.trim());
      sb.writeln();
      sb.writeln('---');
      sb.writeln();
    }

    // manual first, then auto
    for (final t in _manual) {
      appendBlock(t, isAuto: false);
    }
    for (final t in _auto) {
      appendBlock(t, isAuto: true);
    }

    return sb.toString().trimRight() + '\n';
  }

  Future<void> _shareAllAsTxt() async {
    final m = _meta;
    if (m == null) {
      await AppFlushbar.success(context, message: 'Not found');
      return;
    }
    if (_manual.isEmpty && _auto.isEmpty) {
      await AppFlushbar.success(context, message: 'Nothing to share');
      return;
    }

    try {
      final safeId = _safeFileId(m.videoId);
      final content = _buildTxtExport();

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/youtube_transcript_$safeId.txt');
      await file.writeAsString(content, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(
              file.path,
              mimeType: 'text/plain',
              name: file.uri.pathSegments.last,
            ),
          ],
          subject: 'YouTube transcript ($safeId)',
          text: 'Exported transcript as .txt',
        ),
      );
    } catch (_) {
      if (!mounted) return;
      await AppFlushbar.success(context, message: 'Failed to share');
    }
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

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('YouTube Transcript')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_meta == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('YouTube Transcript')),
        body: const Center(child: Text('Not found')),
      );
    }

    final url = _bestUrl(_meta!);

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text('YouTube Transcript'),
        actions: [

          // ✅ Share button (pill too)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: _IconPillButton(
              tooltip: 'Share .txt',
              icon: Icons.ios_share,
              onTap: (_manual.isNotEmpty || _auto.isNotEmpty)
                  ? _shareAllAsTxt
                  : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _IconPillButton(
              tooltip: 'Back',
              icon: Icons.close,
              onTap: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          children: [
            // Top meta panel (link + copy + generate again)
            Container(
              decoration: BoxDecoration(
                color: panelBg,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: panelBorder),
              ),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Video link',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: panelBorder),
                      color: isDark
                          ? Colors.white.withOpacity(0.06)
                          : Colors.black.withOpacity(0.04),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.link, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            url,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Copy link',
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: url));
                            if (mounted) {
                              await AppFlushbar.success(
                                context,
                                message: 'Copied link',
                              );
                            }
                          },
                          icon: const Icon(Icons.copy),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Generate again
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _regenerating ? null : _regenerate,
                          icon: _regenerating
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.auto_fix_high,color: Colors.white,),
                          label: Text(
                            _regenerating ? 'Generating…' : 'Generate again',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _MiniPill(
                        label: 'Video ID: ${_meta!.videoId}',
                        isDark: isDark,
                      ),
                      _MiniPill(
                        label: 'Manual: ${_manual.length}',
                        isDark: isDark,
                      ),
                      _MiniPill(label: 'Auto: ${_auto.length}', isDark: isDark),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),

            _SectionHeader(
              title: 'Manual transcripts',
              subtitle: _manual.isEmpty
                  ? 'None'
                  : '${_manual.length} available',
            ),
            const SizedBox(height: 10),
            _manual.isEmpty
                ? const _EmptySmall(
                    text: 'No manual transcripts for this video.',
                  )
                : _DbTranscriptList(items: _manual),

            const SizedBox(height: 16),

            _SectionHeader(
              title: 'Auto-generated transcripts',
              subtitle: _auto.isEmpty ? 'None' : '${_auto.length} available',
            ),
            const SizedBox(height: 10),
            _auto.isEmpty
                ? const _EmptySmall(
                    text: 'No auto-generated transcripts for this video.',
                  )
                : _DbTranscriptList(items: _auto),

            const SizedBox(height: 72),
          ],
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

class _DbTranscriptList extends StatelessWidget {
  const _DbTranscriptList({required this.items});
  final List<YoutubeTranscriptTextEntity> items;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final panelBg = isDark
        ? const Color(0xFF101018)
        : Theme.of(context).colorScheme.surface;
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
        itemBuilder: (ctx, i) => _DbTranscriptCard(item: items[i]),
      ),
    );
  }
}

class _DbTranscriptCard extends StatelessWidget {
  const _DbTranscriptCard({required this.item});
  final YoutubeTranscriptTextEntity item;

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
                      const SizedBox(width: 8),
                      _GenTag(isGenerated: item.isGenerated),
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

class _GenTag extends StatelessWidget {
  const _GenTag({required this.isGenerated});
  final bool isGenerated;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = isGenerated ? 'AUTO' : 'MANUAL';

    final color = Colors.white;
    final border = color.withOpacity(isDark ? 0.50 : 0.35);
    final bg = color.withOpacity(isDark ? 0.16 : 0.10);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w900,
          letterSpacing: 0.2,
          color: color,
        ),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
