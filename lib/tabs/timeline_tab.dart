import 'dart:io';

import 'package:flutter/material.dart';
import 'package:transcript/onboarding/enroll_flow.dart';

import '../debug/speaker_memory_page.dart';
import '../model_picker_page.dart';
import '../objectbox/entities.dart';
import '../objectbox/objectbox_store.dart';
import '../objectbox.g.dart';
import '../transcript/transcript_detail_page.dart';

import '../common/confirm_dialog.dart';
import '../common/app_flushbar.dart';

class TimelineTab extends StatefulWidget {
  const TimelineTab({super.key, required this.onNavigateToTab});
  final void Function(int tabIndex) onNavigateToTab;

  @override
  State<TimelineTab> createState() => _TimelineTabState();
}

class _TimelineTabState extends State<TimelineTab> {
  final ScrollController _recentCtrl = ScrollController();
  List<TranscriptEntity> _items = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _recentCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);

    final box = ObjectBox.I.transcripts;
    final qb = box.query()
      ..order(TranscriptEntity_.createdAt, flags: Order.descending);
    final q = qb.build();
    try {
      _items = q.find();
    } finally {
      q.close();
    }

    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _refresh() => _load();

  void _scrollRecentToTop() {
    if (_recentCtrl.hasClients) {
      _recentCtrl.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _deleteTranscriptCascade(int transcriptId) async {
  final store = ObjectBox.I.store;

  final transcriptsBox = store.box<TranscriptEntity>();
  final turnsBox = store.box<TranscriptTurnEntity>();
  final summaryBox = store.box<TranscriptSummaryEntity>();
  final chatsBox = store.box<TranscriptChatMessageEntity>();

  // Read audioPath BEFORE deleting transcript
  final transcript = transcriptsBox.get(transcriptId);
  final audioPath = transcript?.audioPath;

  // Best-effort delete audio file (outside transaction is fine)
  if (audioPath != null && audioPath.trim().isNotEmpty) {
    try {
      final f = File(audioPath);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {
      // swallow errors: missing permissions, already deleted, etc.
      // optional: log to your logger if you have one
    }
  }

  // Cascade delete DB rows in one write transaction
  store.runInTransaction(TxMode.write, () {
    // 1) Delete turns
    final turnsQ = turnsBox
        .query(TranscriptTurnEntity_.transcript.equals(transcriptId))
        .build();
    try {
      final turnIds = turnsQ.findIds();
      if (turnIds.isNotEmpty) turnsBox.removeMany(turnIds);
    } finally {
      turnsQ.close();
    }

    // 2) Delete summary row(s)
    final sumQ = summaryBox
        .query(TranscriptSummaryEntity_.transcriptId.equals(transcriptId))
        .build();
    try {
      final sumIds = sumQ.findIds();
      if (sumIds.isNotEmpty) summaryBox.removeMany(sumIds);
    } finally {
      sumQ.close();
    }

    // 3) Delete chats
    final chatQ = chatsBox
        .query(TranscriptChatMessageEntity_.transcriptId.equals(transcriptId))
        .build();
    try {
      final chatIds = chatQ.findIds();
      if (chatIds.isNotEmpty) chatsBox.removeMany(chatIds);
    } finally {
      chatQ.close();
    }

    // 4) Delete transcript itself
    transcriptsBox.remove(transcriptId);
  });

  await _load();
}

  Future<void> _onDeletePressed(TranscriptEntity t) async {
    final ok = await showConfirmDeleteDialog(
      context,
      title: 'Delete transcript?',
      message:
          'This will permanently delete the transcript, its summary, and all related chats.',
    );
    if (!ok) return;

    await _deleteTranscriptCascade(t.id);

    if (!mounted) return;
    await AppFlushbar.success(context, message: 'Transcript deleted');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Timeline'),
        actions: [
          IconButton(
            tooltip: 'Scroll transcripts to top',
            icon: const Icon(Icons.vertical_align_top),
            onPressed: _scrollRecentToTop,
          )
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Quick actions header
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text('Quick actions',
                    style: theme.textTheme.titleMedium),
              ),

              // Quick actions grid (NOT scrollable)
              GridView.count(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.8,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _ActionCard(
                    icon: Icons.mic,
                    title: 'Quick record',
                    subtitle: 'Start a new recording',
                    onTap: () => widget.onNavigateToTab(2),
                  ),
                  _ActionCard(
                    icon: Icons.person_search,
                    title: 'People',
                    subtitle: 'Manage enrolled speakers',
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SpeakerMemoryPage()),
                      );
                    },
                  ),
                  _ActionCard(
                    icon: Icons.download_for_offline_outlined,
                    title: 'Models',
                    subtitle: 'Choose Whisper model',
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ModelPickerPage()),
                      );
                    },
                  ),
                  _ActionCard(
                    icon: Icons.people,
                    title: 'Enroll Voice',
                    subtitle: 'Record voice for detection',
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const EnrollmentFlowPage()),
                      );
                    },
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // Recent transcripts header row
              Row(
                children: [
                  Expanded(
                    child: Text('Recent transcripts',
                        style: theme.textTheme.titleMedium),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: _loading ? null : _load,
                    icon: _loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  )
                ],
              ),

              const SizedBox(height: 8),

              // Only this area scrolls
              Expanded(
                child: Card(
                  elevation: 0.6,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: RefreshIndicator.adaptive(
                    onRefresh: _refresh,
                    child: _items.isEmpty
                        ? ListView(
                            controller: _recentCtrl,
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                                child: Center(
                                  child: Text(
                                    'No transcripts yet.\nTap “Quick record” to start.',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodyMedium
                                        ?.copyWith(color: Colors.white70),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : ListView.separated(
                            controller: _recentCtrl,
                            physics: const AlwaysScrollableScrollPhysics(),
                            itemCount: _items.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1, thickness: 0.6),
                            itemBuilder: (ctx, i) {
                              final t = _items[i];
                              final title = (t.title?.trim().isNotEmpty ?? false)
                                  ? t.title!.trim()
                                  : 'Untitled transcript';
                              final when = t.createdAt;
                              final sub =
                                  '${_fmtDate(when)} • ${_fmtDuration(t.durationSec)} • ${t.model}';

                              return ListTile(
                                title: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(sub),
                                leading: const Icon(Icons.article_outlined),
                                trailing: PopupMenuButton<String>(
                                  onSelected: (v) async {
                                    if (v == 'delete') {
                                      await _onDeletePressed(t);
                                    }
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Row(
                                        children: [
                                          Icon(Icons.delete_outline, color: Colors.red),
                                          SizedBox(width: 10),
                                          Text('Delete'),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                onTap: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => TranscriptDetailPage(transcriptId: t.id),
                                    ),
                                  );
                                },
                              );
                            },
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

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Theme.of(context).colorScheme.surface,
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.white70),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    )
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
