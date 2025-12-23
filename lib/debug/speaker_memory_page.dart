// lib/debug/speaker_memory_page.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:transcript/common/app_flushbar.dart';

import '../speaker_memory.dart';

class SpeakerMemoryPage extends StatefulWidget {
  const SpeakerMemoryPage({super.key});
  @override
  State<SpeakerMemoryPage> createState() => _SpeakerMemoryPageState();
}

class _SpeakerMemoryPageState extends State<SpeakerMemoryPage> {
  bool _loading = true;
  String _jsonPretty = '[]';
  List<_Row> _rows = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    final mem = await SpeakerMemory.instance();
    final map = mem.dumpAll(); // Map<String, Float32List>

    final rows = <_Row>[];
    map.forEach((name, emb) {
      rows.add(_Row(name: name, count: 1, dim: emb.length));
    });
    rows.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final jsonMap = <String, List<double>>{};
    map.forEach((name, emb) {
      jsonMap[name] = emb.map((e) => e.toDouble()).toList();
    });
    final encoded = json.encode(jsonMap);
    final pretty =
        const JsonEncoder.withIndent('  ').convert(json.decode(encoded));

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
    // ScaffoldMessenger.of(context).showSnackBar(
    //   const SnackBar(content: Text('Copied SpeakerMemory JSON')),
    // );
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all profiles?'),
        content: const Text('This will remove every enrolled speaker.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final mem = await SpeakerMemory.instance();
    await mem.clearAll();
    if (mounted) {
      await AppFlushbar.success(context, message: 'All Profiles Cleared');
      await _load();
    }
  }

  Future<void> _delete(String name) async {
    final mem = await SpeakerMemory.instance();
    await mem.remove(name);
    if (mounted) {
      await _load();
      await AppFlushbar.success(context, message: 'Deleted $name');
      // ScaffoldMessenger.of(context).showSnackBar(
      //   SnackBar(content: Text('Deleted $name')),
      // );
    }
  }

  void _openVectors(String name) async {
    final mem = await SpeakerMemory.instance();
    final map = mem.dumpAll();
    final emb = map[name];

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
              emb == null
                  ? '$name • no embedding'
                  : '$name • 1 vector (dim ${emb.length})',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            if (emb != null)
              Expanded(
                child: ListView(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.graphic_eq),
                      title: const Text('Vector 1'),
                      subtitle: Text('dim = ${emb.length}'),
                    ),
                  ],
                ),
              )
            else
              const Expanded(
                child: Center(
                  child: Text(
                    'No vector stored for this speaker.',
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
                              subtitle:
                                  Text('vectors: ${r.count} • dim: ${r.dim}'),
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
                  Card(
                    child: ExpansionTile(
                      title: const Text(
                          'Raw JSON (current in-memory + persisted view)'),
                      children: [
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: SelectableText(
                              _jsonPretty,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12.5,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
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
