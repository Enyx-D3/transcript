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

import '../settings/settings_page.dart';

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

  void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);

    final box = ObjectBox.I.transcripts;

    Query<TranscriptEntity>? q;
    try {
      final qb = box.query()
        ..order(TranscriptEntity_.createdAt, flags: Order.descending);
      q = qb.build();
      _items = q.find();
    } finally {
      q?.close();
    }

    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _refresh() => _load();

  Future<void> _deleteTranscriptCascade(int transcriptId) async {
    final store = ObjectBox.I.store;

    final transcriptsBox = store.box<TranscriptEntity>();
    final turnsBox = store.box<TranscriptTurnEntity>();
    final summaryBox = store.box<TranscriptSummaryEntity>();
    final chatsBox = store.box<TranscriptChatMessageEntity>();

    final transcript = transcriptsBox.get(transcriptId);
    final audioPath = transcript?.audioPath;

    if (audioPath != null && audioPath.trim().isNotEmpty) {
      try {
        final f = File(audioPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }

    store.runInTransaction(TxMode.write, () {
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

      transcriptsBox.remove(transcriptId);
    });

    await _load();
  }

  Future<void> _onDeletePressed(TranscriptEntity t) async {
    _unfocus();

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
      appBar: AppBar(title: const Text('Timeline')),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _unfocus,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text('Quick actions', style: theme.textTheme.titleMedium),
                ),
                GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.8,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _ActionCard(
                      icon: Icons.settings,
                      title: 'Settings',
                      subtitle: 'App preferences',
                      onTap: () async {
                        _unfocus();
                        await Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const SettingsPage()),
                        );
                        _unfocus();
                      },
                    ),
                    _ActionCard(
                      icon: Icons.person_search,
                      title: 'People',
                      subtitle: 'Manage enrolled speakers',
                      onTap: () async {
                        _unfocus();
                        await Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const SpeakerMemoryPage()),
                        );
                        _unfocus();
                      },
                    ),
                    _ActionCard(
                      icon: Icons.download_for_offline_outlined,
                      title: 'Models',
                      subtitle: 'Download model for AI features',
                      onTap: () async {
                        _unfocus();
                        await Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const ModelPickerPage()),
                        );
                        _unfocus();
                      },
                    ),
                    _ActionCard(
                      icon: Icons.people,
                      title: 'Enroll Voice',
                      subtitle: 'Record voice for detection',
                      onTap: () async {
                        _unfocus();
                        await Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const EnrollmentFlowPage()),
                        );
                        _unfocus();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),

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
                                  padding:
                                      const EdgeInsets.fromLTRB(16, 24, 16, 24),
                                  child: Center(
                                    child: Text(
                                      'No transcripts yet.\nTap “Record” tab to start.',
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
                                            Icon(Icons.delete_outline,
                                                color: Colors.red),
                                            SizedBox(width: 10),
                                            Text('Delete'),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  onTap: () async {
                                    _unfocus();
                                    await Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            TranscriptDetailPage(transcriptId: t.id),
                                      ),
                                    );
                                    _unfocus();
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
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => onTap(),
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
