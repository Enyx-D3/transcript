import 'package:flutter/material.dart';

import '../common/app_flushbar.dart';
import 'app_prefs.dart';

// ✅ NEW
import '../import_export/transcript_porter.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _loading = true;
  bool _allowLong = false;

  bool _busyExport = false;
  bool _busyImport = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await AppPrefs.getAllowLongRecording();
    if (!mounted) return;
    setState(() {
      _allowLong = v;
      _loading = false;
    });
  }

  Future<void> _onToggle(bool next) async {
    if (!next) {
      await AppPrefs.setAllowLongRecording(false);
      if (!mounted) return;
      setState(() => _allowLong = false);
      await AppFlushbar.success(context, message: 'Long recording disabled');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enable long recordings?'),
        content: const Text(
          'Long recordings can use a lot of memory and storage.\n\n'
          'This may reduce app performance and could cause the app to crash on some devices.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Enable'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    await AppPrefs.setAllowLongRecording(true);
    if (!mounted) return;
    setState(() => _allowLong = true);
    await AppFlushbar.success(context, message: 'Long recording enabled');
  }

  // ----------------------------
  // ZIP Export/Import
  // ----------------------------

  Future<void> _exportZip() async {
    if (_busyExport || _busyImport) return;
    setState(() => _busyExport = true);

    try {
      await TranscriptPorter.exportZipAndShare(includeAudio: true);
      if (!mounted) return;
      await AppFlushbar.success(context, message: 'Export ready to share (ZIP).');
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Export failed: $e');
    } finally {
      if (mounted) setState(() => _busyExport = false);
    }
  }

  Future<void> _importZip() async {
    if (_busyExport || _busyImport) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import transcripts + audio?'),
        content: const Text(
          'This will add transcripts (and their audio if included) from a ZIP export into your database.\n\n'
          'Duplicates are not automatically removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Import'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    setState(() => _busyImport = true);

    try {
      final n = await TranscriptPorter.pickAndImportZip();
      if (!mounted) return;

      if (n == 0) {
        await AppFlushbar.success(context, message: 'No file selected.');
      } else {
        await AppFlushbar.success(context, message: 'Imported $n transcripts.');
      }
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Import failed: $e');
    } finally {
      if (mounted) setState(() => _busyImport = false);
    }
  }

  Widget _busyTrailing(bool busy) {
    return busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.chevron_right);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
              children: [
                Card(
                  elevation: 0.6,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: SwitchListTile(
                    title: const Text('Allow long recordings'),
                    subtitle: const Text(
                      'Default recordings are limited to 30 minutes.\n'
                      'Enable to allow recordings longer than the default limit.',
                    ),
                    value: _allowLong,
                    onChanged: _onToggle,
                  ),
                ),

                const SizedBox(height: 12),

                Card(
                  elevation: 0.6,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.archive_outlined),
                        title: const Text('Export transcripts + audio (ZIP)'),
                        subtitle: const Text('Share to Drive / device / email'),
                        trailing: _busyTrailing(_busyExport),
                        enabled: !_busyExport && !_busyImport,
                        onTap: (!_busyExport && !_busyImport) ? _exportZip : null,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.unarchive_outlined),
                        title: const Text('Import transcripts + audio (ZIP)'),
                        subtitle: const Text('Pick ZIP from device / Drive'),
                        trailing: _busyTrailing(_busyImport),
                        enabled: !_busyExport && !_busyImport,
                        onTap: (!_busyExport && !_busyImport) ? _importZip : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
