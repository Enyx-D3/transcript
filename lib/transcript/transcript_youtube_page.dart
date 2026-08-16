// lib/transcript/transcript_youtube_page.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:transcript/widgets/icon_pill_button.dart';
import 'package:transcript/widgets/solid_section_toolbar.dart';
import 'package:youtube_transcript_api/youtube_transcript_api.dart';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../common/app_flushbar.dart';

// ObjectBox
import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';

// ✅ Glass primitives
import '../ui/glass/glass_background.dart';
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_button.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';

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
    Future<void> gap() => Future.delayed(const Duration(seconds: 1));

    try {
      final list = await api.list(vid);

      final manualTracks = list.where((t) => t.isGenerated == false).toList();
      final autoTracks = list.where((t) => t.isGenerated == true).toList();

      final manualItems = <_TranscriptItem>[];
      final autoItems = <_TranscriptItem>[];

      bool rateLimited = false;

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

      if (!mounted) return;

      setState(() {
        _manual = manualItems;
        _auto = autoItems;
      });

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
      final msg = _isRateLimitError(e) ? kRateLimitMsg : 'Failed to fetch.';
      await AppFlushbar.success(context, message: msg);
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
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    final manualSubtitle = !_hasFetched
        ? 'Not fetched yet'
        : (_manual.isEmpty ? 'None' : '${_manual.length} available');

    final autoSubtitle = !_hasFetched
        ? 'Not fetched yet'
        : (_auto.isEmpty ? 'None' : '${_auto.length} available');

    final canShare =
        _hasFetched && !_loading && (_manual.isNotEmpty || _auto.isNotEmpty);

    return Scaffold(
      backgroundColor: GlassTokens.backgroundColor(context),
      body: GlassBackground(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _unfocus,
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 18),
              children: [
                // ================= "FAKE APP BAR" (part of page) =================
                _TopBar(
                  title: 'YouTube Transcripts',
                  onClose: () => Navigator.of(context).pop(),
                  onShare: canShare ? _shareAllAsTxt : null,
                ),

                const SizedBox(height: 12),

                // ================= INPUT PANEL =================
                GlassCard(
                  variant: GlassCardVariant.panel,
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Paste a YouTube link',
                        style: TextStyle(
                          color: fg,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.1,
                        ),
                      ),
                      const SizedBox(height: 10),

                      // input
                      LiquidGlass(
                        borderRadius: BorderRadius.circular(14),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        shadow: false,
                        blurX: isDark ? 18 : 14,
                        blurY: isDark ? 18 : 14,
                        tintOpacityDark: 0.040,
                        tintOpacityLight: 0.032,
                        borderOpacityDark: 0.14,
                        borderOpacityLight: 0.18,
                        child: TextField(
                          controller: _ctrl,
                          cursorColor: GlassTokens.primary(context),
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _loading ? null : _fetchAll(),
                          style: TextStyle(color: fg),
                          decoration: InputDecoration(
                            hintText: 'https://www.youtube.com/watch?v=...',
                            hintStyle: TextStyle(color: muted),
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

                      const SizedBox(height: 12),

                      GlassButton(
                        kind: GlassButtonKind.primary,
                        label: _loading ? 'Getting…' : 'Get transcripts',
                        icon: _loading
                            ? Icons.hourglass_top_rounded
                            : Icons.subtitles,
                        onPressed: _loading ? null : _fetchAll,
                      ),

                      if (_videoId != null) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            _MetaPill(text: 'Video ID • $_videoId'),
                            _MetaPill(text: 'Manual • ${_manual.length}'),
                            _MetaPill(text: 'Auto • ${_auto.length}'),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                // ================= MANUAL =================
                _SectionHeader(
                  title: 'Manual transcripts',
                  subtitle: manualSubtitle,
                ),
                const SizedBox(height: 10),
                if (_manual.isEmpty)
                  _hasFetched
                      ? const _InlineHint(
                          text: 'No manual transcripts for this video.',
                        )
                      : const _InlineHint(
                          text:
                              'Paste a link above, then tap “Get transcripts”.',
                        )
                else
                  _TranscriptList(items: _manual),

                const SizedBox(height: 16),

                // ================= AUTO =================
                _SectionHeader(
                  title: 'Auto-generated transcripts',
                  subtitle: autoSubtitle,
                ),
                const SizedBox(height: 10),
                if (_auto.isEmpty)
                  _hasFetched
                      ? const _InlineHint(
                          text: 'No auto-generated transcripts for this video.',
                        )
                      : const _InlineHint(
                          text:
                              'Auto transcripts will appear here after fetching.',
                        )
                else
                  _TranscriptList(items: _auto),

                const SizedBox(height: 60),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.onClose,
    required this.onShare,
  });

  final String title;
  final VoidCallback onClose;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context);

    // ✅ No GlassCard behind this bar (per your request)
    return Padding(
      padding: const EdgeInsets.only(left: 2, right: 2),
      child: Row(
        children: [
          IconPillButton(tooltip: 'Close', icon: Icons.close, onTap: onClose),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fg,
                fontSize: 18,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.2,
              ),
            ),
          ),
          const SizedBox(width: 10),
          IconPillButton(
            tooltip: 'Share .txt',
            icon: Icons.ios_share,
            onTap: onShare,
          ),
        ],
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
    return GlassCard(
      variant: GlassCardVariant.panel,
      padding: EdgeInsets.zero,
      child: ListView.separated(
        itemCount: items.length,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        separatorBuilder: (_, _) => const GlassDivider(),
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
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);

    final langName = (item.language?.trim().isNotEmpty ?? false)
        ? item.language!.trim()
        : 'Unknown';
    final code = (item.languageCode?.trim().isNotEmpty ?? false)
        ? item.languageCode!.trim()
        : '--';
    final langLabel = '$langName  [$code]';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                  blurX: isDark ? 14 : 12,
                  blurY: isDark ? 14 : 12,
                  tintOpacityDark: 0.040,
                  tintOpacityLight: 0.032,
                  borderOpacityDark: 0.14,
                  borderOpacityLight: 0.18,
                  child: Row(
                    children: [
                      Icon(Icons.language, size: 16, color: fg),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          langLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: fg,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.1,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconPillButton(
                tooltip: 'Copy',
                icon: Icons.copy,
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: item.text));
                  if (context.mounted) {
                    await AppFlushbar.success(
                      context,
                      message: 'Copied transcript',
                    );
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          LiquidGlass(
            borderRadius: BorderRadius.circular(16),
            padding: const EdgeInsets.all(12),
            shadow: false,
            blurX: isDark ? 18 : 14,
            blurY: isDark ? 18 : 14,
            tintOpacityDark: 0.040,
            tintOpacityLight: 0.032,
            borderOpacityDark: 0.14,
            borderOpacityLight: 0.18,
            child: _ExpandableTranscriptBox(text: item.text, previewLines: 6),
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
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w900,
              fontSize: 16,
              letterSpacing: -0.1,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: TextStyle(
              color: muted,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);

    return LiquidGlass(
      borderRadius: BorderRadius.circular(999),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      shadow: false,
      blurX: isDark ? 14 : 12,
      blurY: isDark ? 14 : 12,
      tintOpacityDark: 0.040,
      tintOpacityLight: 0.032,
      borderOpacityDark: 0.14,
      borderOpacityLight: 0.18,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: fg.withValues(alpha: 0.85),
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _InlineHint extends StatelessWidget {
  const _InlineHint({required this.text});
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

class _ExpandableTranscriptBox extends StatefulWidget {
  const _ExpandableTranscriptBox({
    required this.text,
    this.previewLines = 6,
    super.key,
  });

  final String text;
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
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);
    final t = widget.text.trim().isEmpty ? '(empty transcript)' : widget.text;

    Widget buildInner({required bool expanded}) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t,
            maxLines: expanded ? null : widget.previewLines,
            overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: TextStyle(
              height: 1.35,
              fontWeight: FontWeight.w600,
              color: fg,
              fontSize: 13.5,
            ),
          ),
          const SizedBox(height: 10),
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
                    color: muted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    expanded ? 'Show less' : 'Show more',
                    style: TextStyle(
                      color: muted,
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
            child: buildInner(expanded: _expanded),
          ),
        ),
      ),
    );
  }
}
