// lib/trash/trash_page.dart
import 'dart:io';
import 'package:flutter/material.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';
import '../common/app_flushbar.dart';
import '../common/confirm_dialog.dart';

class TrashPage extends StatefulWidget {
  const TrashPage({super.key});

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  List<TranscriptEntity> _items = [];
  bool _loading = false;

  static const Color _bg = Color(0xFF0B0C10);

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
    _items = q.find();
    q.close();

    if (!mounted) return;
    setState(() => _loading = false);
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

  // ✅ Hard delete (cascade) — copied from your TimelineTab logic
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

    for (final t in _items) {
      await _deleteTranscriptCascade(t.id);
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
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 18),
          children: [
            // ================= HEADER =================
            Row(
              children: [
                _IconPillButton(
                  tooltip: 'Back',
                  icon: Icons.arrow_back,
                  onTap: () => Navigator.of(context).maybePop(),
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
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _PillButton(
                  text: 'Empty',
                  icon: Icons.delete_sweep_outlined,
                  enabled: _items.isNotEmpty && !_loading,
                  accent: Colors.redAccent,
                  onTap: _emptyTrash,
                ),
              ],
            ),

            const SizedBox(height: 12),

            // ================= CONTENT =================
            if (_loading)
              const _Panel(
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Loading…',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
              )
            else if (_items.isEmpty)
              _Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Trash is empty',
                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Deleted transcripts will appear here. You can restore them or delete permanently.',
                      style: TextStyle(color: Colors.white70, height: 1.35),
                    ),
                  ],
                ),
              )
            else ...[
              Row(
                children: [
                  Text(
                    'Deleted transcripts',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
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

                final isYoutube = (t.sourceType ?? 0) == 1;
                final when = _fmtDeleted(t.deletedAt);

                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _TrashCard(
                    title: title,
                    subtitle: 'Deleted: $when',
                    badge: isYoutube ? 'YouTube' : 'Voice',
                    onRestore: () => _restore(t.id),
                    onDeleteNow: () => _deleteNow(t.id),
                    isDark: isDark,
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}

// ===================== UI HELPERS =====================

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = isDark ? const Color(0xFF101018) : theme.colorScheme.surface;
    final border = isDark
        ? Colors.white.withOpacity(0.10)
        : Colors.black.withOpacity(0.08);

    return Container(
      decoration: BoxDecoration(
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
      ),
      padding: const EdgeInsets.all(14),
      child: child,
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

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: (isDark ? Colors.white : Colors.black).withOpacity(0.06),
            border: Border.all(
              color: (isDark ? Colors.white : Colors.black).withOpacity(0.10),
            ),
          ),
          child: Icon(icon, size: 20, color: Colors.white),
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
        color: (c ?? Colors.white).withOpacity(0.06),
        border: Border.all(color: (c ?? Colors.white).withOpacity(0.12)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: c != null ? c.withOpacity(0.95) : Colors.white70,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.text,
    required this.icon,
    required this.enabled,
    required this.onTap,
    this.accent,
  });

  final String text;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final c = accent ?? Colors.white;

    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: enabled ? onTap : null,
        child: Ink(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: c.withOpacity(0.10),
            border: Border.all(color: c.withOpacity(0.18)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: c.withOpacity(0.95)),
              const SizedBox(width: 8),
              Text(
                text,
                style: TextStyle(
                  color: c.withOpacity(0.95),
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
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
    required this.isDark,
  });

  final String title;
  final String subtitle;
  final String badge;
  final VoidCallback onRestore;
  final VoidCallback onDeleteNow;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return _Panel(
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
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.1,
                    fontSize: 15.5,
                    color: Colors.white,
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
            style: const TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.restore_rounded, size: 18),
                  label: const Text('Restore'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: onRestore,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.delete_forever, size: 18),
                  label: const Text('Delete'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    foregroundColor: Colors.redAccent,
                    side: BorderSide(color: Colors.redAccent.withOpacity(0.65)),
                  ),
                  onPressed: onDeleteNow,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
