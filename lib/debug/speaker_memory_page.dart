// lib/debug/speaker_memory_page.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:transcript/common/app_flushbar.dart';
import 'package:transcript/common/confirm_dialog.dart';

import '../speaker_memory.dart';

class SpeakerMemoryPage extends StatefulWidget {
  const SpeakerMemoryPage({super.key});
  @override
  State<SpeakerMemoryPage> createState() => _SpeakerMemoryPageState();
}

class _SpeakerMemoryPageState extends State<SpeakerMemoryPage> {
  bool _loading = true;
  String _jsonPretty = '{}';
  List<_Row> _rows = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    final mem = await SpeakerMemory.instance();
    final map = mem.dumpAll();

    final rows = <_Row>[];
    final jsonMap = <String, List<List<double>>>{};

    map.forEach((name, protos) {
      final count = protos.length;
      final dim = count == 0 ? 0 : protos.first.length;

      rows.add(_Row(name: name, count: count, dim: dim));

      jsonMap[name] = protos.map((emb) => emb.map((e) => e.toDouble()).toList()).toList();
    });

    rows.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final pretty = const JsonEncoder.withIndent('  ').convert(jsonMap);

    if (!mounted) return;
    setState(() {
      _rows = rows;
      _jsonPretty = pretty;
      _loading = false;
    });
  }

  Future<void> _copyJson() async {
    await Clipboard.setData(ClipboardData(text: _jsonPretty));
    if (!mounted) return;
    await AppFlushbar.success(context, message: 'JSON Copied');
  }

  Future<void> _clearAll() async {
    final confirmed = await showConfirmDeleteDialog(
      context,
      title: 'Clear all profiles?',
      message: 'This will remove every enrolled speaker. This action cannot be undone.',
      confirmText: 'Clear All',
    );

    if (!confirmed) return;

    setState(() => _loading = true);
    final mem = await SpeakerMemory.instance();
    await mem.clearAll();

    if (!mounted) return;
    AppFlushbar.success(context, message: 'All Profiles Cleared');
    await _load();
  }

  Future<void> _delete(String name) async {
    final confirmed = await showConfirmDeleteDialog(
      context,
      title: 'Delete Profile?',
      message: 'Are you sure you want to delete the profile for "$name"?',
    );

    if (!confirmed) return;

    final mem = await SpeakerMemory.instance();
    await mem.remove(name);

    if (!mounted) return;
    AppFlushbar.success(context, message: 'Deleted $name');
    await _load();
  }

  void _openVectors(String name) async {
    final mem = await SpeakerMemory.instance();
    final map = mem.dumpAll();
    final protos = map[name] ?? const <Float32List>[];

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xFF0B0C10),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const _LeadingPillIcon(icon: Icons.person),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: Colors.white.withOpacity(0.06),
                      border: Border.all(color: Colors.white.withOpacity(0.10)),
                    ),
                    child: Text(
                      protos.isEmpty
                          ? 'No vectors'
                          : '${protos.length} vectors • dim ${protos.first.length}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (protos.isNotEmpty)
                Expanded(
                  child: ListView.separated(
                    itemCount: protos.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final v = protos[i];
                      return ListTile(
                        leading: const _LeadingPillIcon(icon: Icons.graphic_eq),
                        title: Text('Vector ${i + 1}'),
                        subtitle: Text('dim = ${v.length}'),
                      );
                    },
                  ),
                )
              else
                const Expanded(
                  child: Center(
                    child: Text(
                      'No vectors stored for this speaker.',
                      style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- UI helpers ----------
  BoxDecoration _panelDecoration(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = isDark ? const Color(0xFF101018) : theme.colorScheme.surface;
    final border = isDark ? Colors.white.withOpacity(0.10) : Colors.black.withOpacity(0.08);

    return BoxDecoration(
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator.adaptive(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
                  children: [
                    // ---------- Header ----------
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Speaker memory',
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Enrolled voice profiles',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: isDark ? Colors.white70 : Colors.black54,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        _IconPillButton(
                          tooltip: 'Copy JSON',
                          icon: Icons.content_copy,
                          onTap: _copyJson,
                        ),
                        const SizedBox(width: 8),
                        _IconPillButton(
                          tooltip: 'Clear all',
                          icon: Icons.delete_sweep,
                          onTap: _clearAll,
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),

                    // ---------- Profiles panel ----------
                    Container(
                      decoration: _panelDecoration(context),
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                'Profiles',
                                style: TextStyle(fontWeight: FontWeight.w900),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(999),
                                  color: Colors.white.withOpacity(0.06),
                                  border: Border.all(color: Colors.white.withOpacity(0.10)),
                                ),
                                child: Text(
                                  '${_rows.length}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w800),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),

                          if (_rows.isEmpty)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text(
                                'No profiles saved yet.',
                                style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                              ),
                            )
                          else
                            Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                color: (isDark ? Colors.white : Colors.black).withOpacity(0.03),
                                border: Border.all(
                                  color: (isDark ? Colors.white : Colors.black).withOpacity(0.08),
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Column(
                                children: [
                                  for (int i = 0; i < _rows.length; i++) ...[
                                    _ProfileRow(
                                      name: _rows[i].name,
                                      meta: 'vectors: ${_rows[i].count} • dim: ${_rows[i].dim}',
                                      onOpen: () => _openVectors(_rows[i].name),
                                      onDelete: () => _delete(_rows[i].name),
                                    ),
                                    if (i != _rows.length - 1)
                                      const Divider(height: 1, thickness: 0.6),
                                  ],
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),

                    // (Optional) You had the Raw JSON ExpansionTile commented out.
                    // Keeping it removed visually, since you commented it out already.

                    const SizedBox(height: 10),
                  ],
                ),
              ),
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.name,
    required this.meta,
    required this.onOpen,
    required this.onDelete,
  });

  final String name;
  final String meta;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const _LeadingPillIcon(icon: Icons.person),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text(meta),
      trailing: IconButton(
        tooltip: 'Delete',
        icon: const Icon(Icons.delete_outline),
        onPressed: onDelete,
      ),
      onTap: onOpen,
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
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: (isDark ? Colors.white : Colors.black).withOpacity(0.06),
          border: Border.all(
            color: (isDark ? Colors.white : Colors.black).withOpacity(0.10),
          ),
        ),
        child: Tooltip(message: tooltip, child: Icon(icon)),
      ),
    );
  }
}

class _LeadingPillIcon extends StatelessWidget {
  const _LeadingPillIcon({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final border = isDark ? Colors.white.withOpacity(0.12) : Colors.black.withOpacity(0.08);
    final bg = isDark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.04);

    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: Icon(icon, size: 20),
    );
  }
}

class _Row {
  const _Row({required this.name, required this.count, required this.dim});
  final String name;
  final int count;
  final int dim;
}
