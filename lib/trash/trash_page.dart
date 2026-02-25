// lib/trash/trash_page.dart
import 'dart:io';
import 'package:flutter/material.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';
import '../common/app_flushbar.dart';
import '../common/confirm_dialog.dart';

// ✅ Glass primitives
import '../ui/glass/glass_background.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';
import '../ui/glass/liquid_glass.dart';

class TrashPage extends StatefulWidget {
  const TrashPage({super.key});

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  List<TranscriptEntity> _items = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);

    final box = ObjectBox.I.store.box<TranscriptEntity>();
    final qb = box.query(TranscriptEntity_.isDeleted.equals(true))
      ..order(TranscriptEntity_.deletedAt, flags: Order.descending);

    final q = qb.build();
    final items = q.find();
    q.close();

    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _restore(int id) async {
    final store = ObjectBox.I.store;
    final box = store.box<TranscriptEntity>();

    store.runInTransaction(TxMode.write, () {
      final t = box.get(id);
      if (t == null) return;
      t.isDeleted = false;
      t.deletedAt = null;
      t.updatedAt = DateTime.now();
      box.put(t);
    });

    await _load();
    if (!mounted) return;
    await AppFlushbar.success(context, message: 'Restored');
  }

  // ✅ Hard delete (cascade)
  Future<void> _deleteTranscriptCascade(int transcriptId) async {
    final store = ObjectBox.I.store;

    final transcriptsBox = store.box<TranscriptEntity>();
    final turnsBox = store.box<TranscriptTurnEntity>();
    final summaryBox = store.box<TranscriptSummaryEntity>();
    final chatsBox = store.box<TranscriptChatMessageEntity>();

    final ytMetaBox = store.box<YoutubeTranscriptMetaEntity>();
    final ytTextBox = store.box<YoutubeTranscriptTextEntity>();

    final transcript = transcriptsBox.get(transcriptId);

    final isYoutube = (transcript?.sourceType ?? 0) == 1;
    final ytMetaId = transcript?.youtubeMetaId;

    final audioPath = transcript?.audioPath;
    if (!isYoutube && audioPath != null && audioPath.trim().isNotEmpty) {
      try {
        final f = File(audioPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }

    store.runInTransaction(TxMode.write, () {
      if (!isYoutube) {
        final turnsQ = turnsBox
            .query(TranscriptTurnEntity_.transcript.equals(transcriptId))
            .build();
        try {
          final ids = turnsQ.findIds();
          if (ids.isNotEmpty) turnsBox.removeMany(ids);
        } finally {
          turnsQ.close();
        }

        final sumQ = summaryBox
            .query(TranscriptSummaryEntity_.transcriptId.equals(transcriptId))
            .build();
        try {
          final ids = sumQ.findIds();
          if (ids.isNotEmpty) summaryBox.removeMany(ids);
        } finally {
          sumQ.close();
        }

        final chatQ = chatsBox
            .query(TranscriptChatMessageEntity_.transcriptId.equals(transcriptId))
            .build();
        try {
          final ids = chatQ.findIds();
          if (ids.isNotEmpty) chatsBox.removeMany(ids);
        } finally {
          chatQ.close();
        }
      }

      if (isYoutube && ytMetaId != null) {
        final tq = ytTextBox
            .query(YoutubeTranscriptTextEntity_.meta.equals(ytMetaId))
            .build();
        try {
          final ids = tq.findIds();
          if (ids.isNotEmpty) ytTextBox.removeMany(ids);
        } finally {
          tq.close();
        }
        ytMetaBox.remove(ytMetaId);
      }

      transcriptsBox.remove(transcriptId);
    });
  }

  Future<void> _deleteNow(int id) async {
    final ok = await showConfirmDeleteDialog(
      context,
      title: 'Delete permanently?',
      message: 'This will permanently delete the transcript and its related data.',
    );
    if (!ok) return;

    await _deleteTranscriptCascade(id);
    await _load();

    if (!mounted) return;
    await AppFlushbar.success(context, message: 'Deleted permanently');
  }

  Future<void> _emptyTrash() async {
    if (_items.isEmpty) return;

    final ok = await showConfirmDeleteDialog(
      context,
      title: 'Empty Trash?',
      message: 'This will permanently delete all items in Trash.',
    );
    if (!ok) return;

    final ids = _items.map((e) => e.id).toList();
    for (final id in ids) {
      await _deleteTranscriptCascade(id);
    }

    await _load();
    if (!mounted) return;
    await AppFlushbar.success(context, message: 'Trash emptied');
  }

  String _fmtDeleted(DateTime? dt) {
    if (dt == null) return '';
    final l = dt.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')} '
        '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = GlassTokens.isDark(context);

    final fg = GlassTokens.fg(context, alpha: 0.92);
    final muted = GlassTokens.muted(context, alpha: 0.70);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GlassBackground(
        child: SafeArea(
          child: Column(
            children: [
              // ✅ header (no AppBar)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  children: [
                    LiquidGlass(
                      borderRadius: BorderRadius.circular(999),
                      padding: const EdgeInsets.all(8),
                      shadow: false,
                      blurX: isDark ? 16 : 12,
                      blurY: isDark ? 16 : 12,
                      tintOpacityDark: 0.040,
                      tintOpacityLight: 0.032,
                      borderOpacityDark: 0.14,
                      borderOpacityLight: 0.18,
                      onTap: () => Navigator.of(context).maybePop(),
                      child: Icon(Icons.arrow_back, color: fg, size: 20),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Trash',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.2,
                          color: fg,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),

                    // ✅ Custom compact header button (never overflows)
                    _HeaderGlassButton(
                      label: 'Empty',
                      icon: Icons.delete_sweep_outlined,
                      enabled: _items.isNotEmpty && !_loading,
                      onTap: _emptyTrash,
                    ),
                  ],
                ),
              ),

              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: GlassDivider(height: 1, thickness: 0.8),
              ),
              const SizedBox(height: 10),

              Expanded(
                child: RefreshIndicator.adaptive(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
                    children: [
                      if (_loading)
                        GlassCard(
                          variant: GlassCardVariant.tile,
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white.withValues(alpha: 0.75),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                'Loading…',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: fg,
                                ),
                              ),
                            ],
                          ),
                        )
                      else if (_items.isEmpty)
                        GlassCard(
                          variant: GlassCardVariant.tile,
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Trash is empty',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 16,
                                  color: fg,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Deleted transcripts will appear here. You can restore them or delete permanently.',
                                style: TextStyle(
                                  color: muted,
                                  height: 1.35,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        )
                      else ...[
                        Row(
                          children: [
                            Text(
                              'Deleted transcripts',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                color: fg,
                                fontSize: 16,
                              ),
                            ),
                            const Spacer(),
                            _MetaPill(text: '${_items.length}'),
                          ],
                        ),
                        const SizedBox(height: 10),
                        ..._items.map((t) {
                          final title = (t.title?.trim().isNotEmpty ?? false)
                              ? t.title!.trim()
                              : 'Untitled transcript';

                          final isYoutube = (t.sourceType) == 1;
                          final isAudio = (t.sourceType) == 2;
                          final isVideo = (t.sourceType) == 3;

                          final when = _fmtDeleted(t.deletedAt);

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _TrashCard(
                              title: title,
                              subtitle: 'Deleted: $when',
                              badge: isYoutube
                                  ? 'YouTube'
                                  : (isAudio ? 'Audio' : (isVideo ? 'Video' : 'Voice')),
                              onRestore: () => _restore(t.id),
                              onDeleteNow: () => _deleteNow(t.id),
                            ),
                          );
                        }),
                      ],
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
}

// ===================== UI HELPERS =====================

class _HeaderGlassButton extends StatelessWidget {
  const _HeaderGlassButton({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.enabled,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context, alpha: enabled ? 0.92 : 0.70);

    // Header space is tight. This keeps it compact AND safe.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 120),
      child: Opacity(
        opacity: enabled ? 1 : 0.55,
        child: LiquidGlass(
          borderRadius: BorderRadius.circular(16),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          shadow: false,
          blurX: 0,
          blurY: 0,
          grain: false,
          tintOpacityDark: isDark ? 0.075 : 0.060,
          tintOpacityLight: isDark ? 0.060 : 0.050,
          borderOpacityDark: isDark ? 0.16 : 0.18,
          borderOpacityLight: isDark ? 0.20 : 0.22,
          onTap: enabled ? onTap : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 6),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.visible, // avoid debug overflow yellows
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w900,
                      fontSize: 13.5,
                      height: 1.0,
                      letterSpacing: 0.1,
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
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.text, this.accent});
  final String text;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final c = accent;
    return Container(
      height: 32,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: (c ?? Colors.white).withValues(alpha: 0.06),
        border: Border.all(color: (c ?? Colors.white).withValues(alpha: 0.12)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: c != null ? c.withValues(alpha: 0.95) : Colors.white70,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _TrashCard extends StatelessWidget {
  const _TrashCard({
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.onRestore,
    required this.onDeleteNow,
  });

  final String title;
  final String subtitle;
  final String badge;
  final VoidCallback onRestore;
  final VoidCallback onDeleteNow;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context, alpha: 0.92);
    final muted = GlassTokens.muted(context, alpha: 0.70);

    return GlassCard(
      variant: GlassCardVariant.tile,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.1,
                    fontSize: 15.5,
                    color: fg,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _MetaPill(text: badge),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              color: muted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),

          // ✅ Buttons that will never overflow in narrow widths
          Row(
            children: [
              Expanded(
                child: _CompactRowButton(
                  label: 'Restore',
                  icon: Icons.restore_rounded,
                  onTap: onRestore,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CompactRowButton(
                  label: 'Delete',
                  icon: Icons.delete_forever,
                  onTap: onDeleteNow,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CompactRowButton extends StatelessWidget {
  const _CompactRowButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context, alpha: 0.92);

    return LayoutBuilder(
      builder: (context, c) {
        final small = c.maxWidth < 150;
        final padV = small ? 10.0 : 12.0;
        final padH = small ? 10.0 : 14.0;
        final fontSize = small ? 13.0 : 14.0;

        return LiquidGlass(
          borderRadius: BorderRadius.circular(16),
          padding: EdgeInsets.symmetric(vertical: padV, horizontal: padH),
          shadow: false,
          blurX: 0,
          blurY: 0,
          grain: false,
          tintOpacityDark: isDark ? 0.075 : 0.060,
          tintOpacityLight: isDark ? 0.060 : 0.050,
          borderOpacityDark: isDark ? 0.16 : 0.18,
          borderOpacityLight: isDark ? 0.20 : 0.22,
          onTap: onTap,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 8),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.visible, // stops yellow overflow warnings
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w900,
                      fontSize: fontSize,
                      height: 1.0,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
