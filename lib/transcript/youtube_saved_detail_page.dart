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

// ✅ Glass primitives
import '../ui/glass/glass_button.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';
import '../ui/glass/liquid_glass.dart';

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

    for (final t in _manual) {
      appendBlock(t, isAuto: false);
    }
    for (final t in _auto) {
      appendBlock(t, isAuto: true);
    }

    return '${sb.toString().trimRight()}\n';
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

  // ============================================================
  // UI
  // ============================================================

  Widget _headerBar({required bool canShare}) {
    final fg = GlassTokens.fg(context);

    return Row(
      children: [
        _GlassIconPill(
          tooltip: 'Close',
          icon: Icons.close,
          onTap: () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'YouTube Transcript',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w900,
              letterSpacing: -0.2,
              color: fg,
            ),
          ),
        ),
        const SizedBox(width: 8),
        _GlassIconPill(
          tooltip: 'Share .txt',
          icon: Icons.ios_share,
          onTap: canShare ? _shareAllAsTxt : null,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = GlassTokens.fg(context);

    // ✅ Loading state (no AppBar)
    if (_loading) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
            child: Column(
              children: [
                _headerBar(canShare: false),
                const SizedBox(height: 14),
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Loading…',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: fg,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // ✅ Not found state (no AppBar)
    if (_meta == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
            child: Column(
              children: [
                _headerBar(canShare: false),
                const SizedBox(height: 14),
                Expanded(
                  child: Center(
                    child: Text(
                      'Not found',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w800,
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

    final url = _bestUrl(_meta!);
    final canShare = (_manual.isNotEmpty || _auto.isNotEmpty);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
          children: [
            // ================= Header (in-page, not AppBar) =================
            _headerBar(canShare: canShare),
            const SizedBox(height: 14),

            // ================= Top meta panel =================
            GlassCard(
              variant: GlassCardVariant.panel,
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Video link',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: fg,
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Link box
                  LiquidGlass(
                    borderRadius: BorderRadius.circular(14),
                    padding: const EdgeInsets.all(12),
                    shadow: false,
                    child: Row(
                      children: [
                        const Icon(Icons.link, size: 18, color: Colors.white70),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            url,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: fg,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Copy link',
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: url));
                            if (!mounted) return;
                            await AppFlushbar.success(
                              context,
                              message: 'Copied link',
                            );
                          },
                          icon: const Icon(Icons.copy, color: Colors.white70),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),
                  const GlassDivider(),
                  const SizedBox(height: 12),

                  // Generate again
                  GlassButton(
                    kind: GlassButtonKind.primary,
                    label: _regenerating ? 'Generating…' : 'Generate again',
                    icon: Icons.auto_fix_high,
                    onPressed: _regenerating ? null : _regenerate,
                  ),

                  const SizedBox(height: 12),

                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _MiniPill(label: 'Video ID: ${_meta!.videoId}'),
                      _MiniPill(label: 'Manual: ${_manual.length}'),
                      _MiniPill(label: 'Auto: ${_auto.length}'),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ================= Manual section =================
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

            const SizedBox(height: 18),

            // ================= Auto section =================
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

            const SizedBox(height: 24),
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

// ===================== LIST =====================

class _DbTranscriptList extends StatelessWidget {
  const _DbTranscriptList({required this.items});
  final List<YoutubeTranscriptTextEntity> items;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      variant: GlassCardVariant.panel,
      padding: EdgeInsets.zero,
      child: ListView.separated(
        itemCount: items.length,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        separatorBuilder: (_, _) => const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: GlassDivider(),
        ),
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
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

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
                child: LiquidGlass(
                  borderRadius: BorderRadius.circular(999),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  shadow: false,
                  child: Row(
                    children: [
                      Icon(
                        Icons.language,
                        size: 16,
                        color: muted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          langLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: fg,
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
              _GlassIconPill(
                tooltip: 'Copy',
                icon: Icons.copy,
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: item.text));
                  if (!context.mounted) return;
                  await AppFlushbar.success(
                    context,
                    message: 'Copied transcript',
                  );
                },
              ),
            ],
          ),

          const SizedBox(height: 10),

          // transcript box
          LiquidGlass(
            borderRadius: BorderRadius.circular(14),
            padding: const EdgeInsets.all(12),
            shadow: false,
            child: _ExpandableTranscriptBox(
              text: item.text,
              previewLines: 6,
              textStyle: theme.textTheme.bodySmall?.copyWith(
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: fg,
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
    final isDark = GlassTokens.isDark(context);
    final label = isGenerated ? 'AUTO' : 'MANUAL';

    final color = isDark ? Colors.white : const Color(0xFF141418);
    final border = color.withValues(alpha: isDark ? 0.50 : 0.25);
    final bg = color.withValues(alpha: isDark ? 0.16 : 0.06);

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
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w900,
              color: fg,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: muted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniPill extends StatelessWidget {
  const _MiniPill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context);

    return LiquidGlass(
      borderRadius: BorderRadius.circular(999),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      shadow: false,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 12),
      ),
    );
  }
}

class _EmptySmall extends StatelessWidget {
  const _EmptySmall({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final muted = GlassTokens.muted(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 4),
      child: Text(
        text,
        style: TextStyle(
          color: muted,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ===================== EXPANDABLE BOX =====================

class _ExpandableTranscriptBox extends StatefulWidget {
  const _ExpandableTranscriptBox({
    required this.text,
    required this.textStyle,
    this.previewLines = 6,
    super.key,
  });

  final String text;
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
    final isDark = GlassTokens.isDark(context);
    final t = widget.text.trim().isEmpty ? '(empty transcript)' : widget.text;

    final controlColor = isDark ? Colors.white70 : Colors.black54;

    Widget buildBox({required bool expanded}) {
      return Column(
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

// ===================== ICON PILL =====================

class _GlassIconPill extends StatelessWidget {
  const _GlassIconPill({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: (isDark ? Colors.white : Colors.black).withValues(
              alpha: 0.06,
            ),
            border: Border.all(
              color: (isDark ? Colors.white : Colors.black).withValues(
                alpha: 0.10,
              ),
            ),
          ),
          child: Icon(
            icon,
            size: 20,
            color: fg.withValues(alpha: onTap == null ? 0.35 : 0.92),
          ),
        ),
      ),
    );
  }
}
