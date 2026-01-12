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

    // NEW: Map<String, List<Float32List>>
    final map = mem.dumpAll();

    final rows = <_Row>[];
    final jsonMap = <String, List<List<double>>>{};

    map.forEach((name, protos) {
      final count = protos.length;
      final dim = count == 0 ? 0 : protos.first.length;

      rows.add(_Row(name: name, count: count, dim: dim));

      jsonMap[name] = protos
          .map((emb) => emb.map((e) => e.toDouble()).toList())
          .toList();
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

    setState(() => _loading = true); // Visual feedback that work is happening
    final mem = await SpeakerMemory.instance();
    await mem.clearAll();

    if (!mounted) return;
    AppFlushbar.success(context, message: 'All Profiles Cleared');
    await _load(); // Refresh the list
    
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
    await _load(); // Refresh the list
    
  }

  void _openVectors(String name) async {
    final mem = await SpeakerMemory.instance();
    final map = mem.dumpAll();
    final protos = map[name] ?? const <Float32List>[];

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).cardColor,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              protos.isEmpty
                  ? '$name • no embeddings'
                  : '$name • ${protos.length} vectors (dim ${protos.first.length})',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            if (protos.isNotEmpty)
              Expanded(
                child: ListView.builder(
                  itemCount: protos.length,
                  itemBuilder: (_, i) {
                    final v = protos[i];
                    return ListTile(
                      leading: const Icon(Icons.graphic_eq),
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
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SpeakerMemory'),
        actions: [
          IconButton(
            tooltip: 'Copy JSON',
            onPressed: _loading ? null : _copyJson,
            icon: const Icon(Icons.content_copy),
          ),
          IconButton(
            tooltip: 'Clear all',
            onPressed: _loading ? null : _clearAll,
            icon: const Icon(Icons.delete_sweep),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Profiles',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 8),
                          if (_rows.isEmpty)
                            const Text(
                              'No profiles saved yet.',
                              style: TextStyle(color: Colors.white70),
                            ),
                          ..._rows.map(
                            (r) => ListTile(
                              leading: const Icon(Icons.person),
                              title: Text(r.name),
                              subtitle: Text(
                                'vectors: ${r.count} • dim: ${r.dim}',
                              ),
                              onTap: () => _openVectors(r.name),
                              trailing: IconButton(
                                tooltip: 'Delete',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _delete(r.name),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Card(
                  //   child: ExpansionTile(
                  //     title: const Text(
                  //       'Raw JSON (current in-memory + persisted view)',
                  //     ),
                  //     children: [
                  //       SingleChildScrollView(
                  //         scrollDirection: Axis.horizontal,
                  //         child: Padding(
                  //           padding: const EdgeInsets.all(12),
                  //           child: SelectableText(
                  //             _jsonPretty,
                  //             style: const TextStyle(
                  //               fontFamily: 'monospace',
                  //               fontSize: 12.5,
                  //               height: 1.35,
                  //             ),
                  //           ),
                  //         ),
                  //       ),
                  //     ],
                  //   ),
                  // ),
                ],
              ),
            ),
    );
  }
}

class _Row {
  const _Row({required this.name, required this.count, required this.dim});
  final String name;
  final int count;
  final int dim;
}
