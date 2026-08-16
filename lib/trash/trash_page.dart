// lib/trash/trash_page.dart
import 'dart:io';
import 'package:flutter/material.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';
import '../common/app_flushbar.dart';
import '../common/confirm_dialog.dart';
import '../widgets/icon_pill_button.dart';

// ✅ Glass primitives
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_tokens.dart';

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
            .query(
              TranscriptChatMessageEntity_.transcriptId.equals(transcriptId),
            )
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
      title: 'Delete forever?',
      message: 'This will permanently remove the transcript.',
      confirmText: 'Delete',
    );
    if (!ok) return;

    await _deleteTranscriptCascade(id);

    await _load();
    if (!mounted) return;
    await AppFlushbar.success(context, message: 'Permanently deleted');
  }

  Future<void> _emptyTrash() async {
    if (_items.isEmpty) return;

    final ok = await showConfirmDeleteDialog(
      context,
      title: 'Empty trash?',
      message: 'All items will be permanently deleted.',
      confirmText: 'Empty trash',
    );
    if (!ok) return;

    final box = ObjectBox.I.store.box<TranscriptEntity>();
    final qb = box.query(TranscriptEntity_.isDeleted.equals(true));
    final q = qb.build();
    final ids = q.findIds();
    q.close();

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
    final fg = GlassTokens.fg(context, alpha: 0.92);
    final muted = GlassTokens.muted(context, alpha: 0.70);
    final isDark = GlassTokens.isDark(context);

    return Scaffold(
      backgroundColor: GlassTokens.backgroundColor(context),
      appBar: AppBar(
        backgroundColor: GlassTokens.backgroundColor(context),
        elevation: 0,
        title: Text(
          'Trash',
          style: TextStyle(
            color: fg,
            fontWeight: FontWeight.w800,
          ),
        ),
        leading: Padding(
          padding: const EdgeInsets.all(7.0),
          child: IconPillButton(
            tooltip: 'Back',
            icon: Icons.arrow_back,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        actions: [
          if (_items.isNotEmpty && !_loading)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Center(
                child: _HeaderButton(
                  label: 'Empty',
                  icon: Icons.delete_sweep_outlined,
                  onTap: _emptyTrash,
                ),
              ),
            ),
        ],
      ),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(
                color: fg,
              ),
            )
          : RefreshIndicator.adaptive(
              onRefresh: _load,
              child: _items.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.fromLTRB(16, 48, 16, 24),
                      children: [
                        Center(
                          child: GlassCard(
                            variant: GlassCardVariant.panel,
                            padding: const EdgeInsets.all(28),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 56,
                                  height: 56,
                                  decoration: BoxDecoration(
                                    color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.05),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.delete_outline_rounded,
                                    size: 28,
                                    color: muted,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'Trash is empty',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 17,
                                    color: fg,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Deleted transcripts will appear here.\nYou can restore them or delete permanently.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: muted,
                                    fontSize: 13,
                                    height: 1.4,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
                      children: [
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
                        const SizedBox(height: 12),
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
                                  : (isAudio
                                      ? 'Audio'
                                      : (isVideo ? 'Video' : 'Voice')),
                              onRestore: () => _restore(t.id),
                              onDeleteNow: () => _deleteNow(t.id),
                            ),
                          );
                        }),
                      ],
                    ),
            ),
    );
  }
}

// ===================== UI HELPERS =====================

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
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
    const dangerColor = Color(0xFFFF3B30);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: dangerColor.withValues(alpha: isDark ? 0.14 : 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: dangerColor.withValues(alpha: isDark ? 0.22 : 0.15),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: dangerColor),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: dangerColor,
                fontWeight: FontWeight.w800,
                fontSize: 12.5,
              ),
            ),
          ],
        ),
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
    return Container(
      height: 28,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: (isDark ? Colors.white : Colors.black).withValues(alpha: isDark ? 0.08 : 0.05),
        border: Border.all(
          color: (isDark ? Colors.white : Colors.black).withValues(alpha: isDark ? 0.14 : 0.08),
        ),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isDark ? Colors.white70 : const Color(0xFF484852),
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
      variant: GlassCardVariant.panel,
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
                    fontWeight: FontWeight.w800,
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
            style: TextStyle(color: muted, fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  label: 'Restore',
                  icon: Icons.restore_rounded,
                  color: const Color(0xFF007AFF),
                  onTap: onRestore,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionButton(
                  label: 'Delete',
                  icon: Icons.delete_forever_rounded,
                  color: const Color(0xFFFF3B30),
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

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? 0.14 : 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: color.withValues(alpha: isDark ? 0.22 : 0.15),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
