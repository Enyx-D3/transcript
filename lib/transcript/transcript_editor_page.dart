import 'dart:async';

import 'package:flutter/material.dart';

import '../common/app_flushbar.dart';
import '../objectbox/objectbox_store.dart';
import '../ui/glass/glass_button.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_tokens.dart';
import '../ui/glass/liquid_glass.dart';
import 'correction_learning.dart';

class TranscriptEditorPage extends StatefulWidget {
  const TranscriptEditorPage({
    super.key,
    required this.transcriptId,
    required this.title,
    required this.initialText,
    required this.fallbackFullTextCache,
  });

  final int transcriptId;
  final String title;
  final String initialText;
  final String fallbackFullTextCache;

  @override
  State<TranscriptEditorPage> createState() => _TranscriptEditorPageState();
}

class _TranscriptEditorPageState extends State<TranscriptEditorPage> {
  static const _kMaxHistory = 100;

  late final TextEditingController _controller;
  final FocusNode _editorFocus = FocusNode();

  final List<String> _undoStack = [];
  final List<String> _redoStack = [];

  Timer? _autoSaveTimer;
  bool _autoSaveEnabled = true;
  bool _saving = false;
  bool _didPersistAnyChange = false;
  bool _suppressListener = false;

  late String _lastSavedText;
  late String _lastSnapshotText;
  DateTime? _lastSavedAt;

  bool get _canUndo => _undoStack.isNotEmpty;
  bool get _canRedo => _redoStack.isNotEmpty;
  bool get _isDirty => _controller.text.trim() != _lastSavedText;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialText.trim();
    _controller = TextEditingController(text: initial);
    _lastSavedText = initial;
    _lastSnapshotText = _controller.text;
    _controller.addListener(_onEditorChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _editorFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _controller.removeListener(_onEditorChanged);
    _controller.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  void _onEditorChanged() {
    if (_suppressListener) return;

    final current = _controller.text;
    if (current != _lastSnapshotText) {
      _pushUndoState(_lastSnapshotText);
      _lastSnapshotText = current;
      _redoStack.clear();
    }

    if (_autoSaveEnabled) {
      _autoSaveTimer?.cancel();
      _autoSaveTimer = Timer(const Duration(milliseconds: 700), () {
        if (!mounted || !_isDirty) return;
        unawaited(_saveChanges(showFeedback: false));
      });
    }

    if (mounted) setState(() {});
  }

  void _pushUndoState(String value) {
    if (_undoStack.isNotEmpty && _undoStack.last == value) return;
    _undoStack.add(value);
    if (_undoStack.length > _kMaxHistory) {
      _undoStack.removeAt(0);
    }
  }

  void _applySnapshot(String value) {
    _suppressListener = true;
    _controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _suppressListener = false;
    _lastSnapshotText = value;
    if (mounted) setState(() {});
  }

  void _undo() {
    if (!_canUndo) return;
    final current = _controller.text;
    final previous = _undoStack.removeLast();
    if (_redoStack.isEmpty || _redoStack.last != current) {
      _redoStack.add(current);
      if (_redoStack.length > _kMaxHistory) {
        _redoStack.removeAt(0);
      }
    }
    _applySnapshot(previous);
  }

  void _redo() {
    if (!_canRedo) return;
    final current = _controller.text;
    final next = _redoStack.removeLast();
    _pushUndoState(current);
    _applySnapshot(next);
  }

  Future<void> _setAutoSave(bool enabled) async {
    if (_autoSaveEnabled == enabled) return;
    setState(() => _autoSaveEnabled = enabled);
    if (enabled && _isDirty) {
      await _saveChanges(showFeedback: false);
    }
  }

  Future<bool> _saveChanges({required bool showFeedback}) async {
    if (_saving) return false;

    final normalized = _controller.text.trim();
    if (normalized == _lastSavedText) {
      if (showFeedback && mounted) {
        await AppFlushbar.info(context, message: 'No changes to save.');
      }
      return false;
    }

    setState(() => _saving = true);
    try {
      final obx = ObjectBox.I;
      final latest = obx.transcripts.get(widget.transcriptId);
      if (latest == null) {
        if (showFeedback && mounted) {
          await AppFlushbar.error(context, message: 'Transcript not found.');
        }
        return false;
      }

      latest.editedText = normalized.isEmpty ? null : normalized;

      final fallback = widget.fallbackFullTextCache.trim();
      latest.fullTextCache = fallback.isEmpty ? null : fallback;
      latest.searchText = normalized.isNotEmpty
          ? normalized
          : (fallback.isEmpty ? null : fallback);

      const CorrectionLearningService().captureTranscriptEdit(
        transcriptId: widget.transcriptId,
        previousText: _lastSavedText,
        editedText: normalized,
        language: latest.lang,
      );

      obx.transcripts.put(latest);

      _lastSavedText = normalized;
      _lastSavedAt = DateTime.now();
      _didPersistAnyChange = true;

      if (showFeedback && mounted) {
        await AppFlushbar.success(context, message: 'Transcript saved.');
      }
      if (mounted) setState(() {});
      return true;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      } else {
        _saving = false;
      }
    }
  }

  Future<bool> _confirmExit() async {
    _autoSaveTimer?.cancel();

    if (_saving) return false;
    if (!_isDirty) return true;

    if (_autoSaveEnabled) {
      await _saveChanges(showFeedback: false);
      return true;
    }

    final decision = await showDialog<_EditorExitAction>(
      context: context,
      builder: (ctx) {
        final isDark = GlassTokens.isDark(ctx);
        final fg = GlassTokens.fg(ctx);
        final muted = GlassTokens.muted(ctx);
        final accent = GlassTokens.primary(ctx);

        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E1E26) : Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Text(
            'Unsaved changes',
            style: TextStyle(color: fg, fontWeight: FontWeight.bold),
          ),
          content: Text(
            'Save your transcript edits before leaving?',
            style: TextStyle(color: muted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(_EditorExitAction.discard),
              child: Text(
                'Discard',
                style: TextStyle(color: muted),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(_EditorExitAction.cancel),
              child: Text(
                'Cancel',
                style: TextStyle(color: fg),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(_EditorExitAction.save),
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('Save', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );

    switch (decision) {
      case _EditorExitAction.save:
        await _saveChanges(showFeedback: false);
        return true;
      case _EditorExitAction.discard:
        return true;
      case _EditorExitAction.cancel:
      case null:
        return false;
    }
  }

  Future<void> _handleBack() async {
    final canLeave = await _confirmExit();
    if (!canLeave || !mounted) return;
    Navigator.of(context).pop(_didPersistAnyChange || _lastSavedAt != null);
  }

  String _statusLabel() {
    if (_saving) return 'Saving…';
    if (_isDirty) {
      return _autoSaveEnabled ? 'Unsaved changes' : 'Manual save mode';
    }
    if (_lastSavedAt != null) return 'Saved';
    return 'Ready';
  }

  String _helperLabel() {
    if (_saving) return 'Please keep this screen open while saving.';
    if (_autoSaveEnabled) {
      return _isDirty
          ? 'Changes will save automatically after you pause typing.'
          : 'Auto-save is on.';
    }
    return _isDirty
        ? 'Tap Save when you are ready.'
        : 'Manual save mode is on.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_handleBack());
      },
      child: Scaffold(
        backgroundColor: GlassTokens.backgroundColor(context),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _EditorIconButton(
                      tooltip: 'Back',
                      icon: Icons.arrow_back,
                      onTap: _handleBack,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Edit Transcript',
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: fg,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: muted,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _EditorIconButton(
                      tooltip: 'Undo',
                      icon: Icons.undo_rounded,
                      onTap: _canUndo ? _undo : null,
                    ),
                    const SizedBox(width: 8),
                    _EditorIconButton(
                      tooltip: 'Redo',
                      icon: Icons.redo_rounded,
                      onTap: _canRedo ? _redo : null,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                GlassCard(
                  variant: GlassCardVariant.panel,
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _StatusPill(
                            label: _statusLabel(),
                            accent: _saving
                                ? Colors.orangeAccent
                                : (_isDirty
                                      ? Colors.amberAccent
                                      : Colors.greenAccent),
                          ),
                          _StatusPill(
                            label: _autoSaveEnabled
                                ? 'Auto-save on'
                                : 'Manual save',
                          ),
                          _StatusPill(label: 'Undo ${_undoStack.length}'),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _helperLabel(),
                        style: TextStyle(
                          color: muted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Switch(
                                  value: _autoSaveEnabled,
                                  onChanged: _saving ? null : _setAutoSave,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Auto-save',
                                    style: TextStyle(
                                      color: fg,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 150,
                            child: GlassButton(
                              kind: GlassButtonKind.primary,
                              label: _saving ? 'Saving…' : 'Save',
                              icon: Icons.save_rounded,
                              loading: _saving,
                              onPressed: _saving
                                  ? null
                                  : () => _saveChanges(showFeedback: true),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Stack(
                      children: [
                        LiquidGlass(
                          borderRadius: BorderRadius.circular(22),
                          padding: EdgeInsets.zero,
                          shadow: false,
                          child: const SizedBox.expand(),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(14),
                          child: TextField(
                            controller: _controller,
                            focusNode: _editorFocus,
                            expands: true,
                            maxLines: null,
                            minLines: null,
                            textAlignVertical: TextAlignVertical.top,
                            keyboardType: TextInputType.multiline,
                            style: TextStyle(
                              color: fg,
                              height: 1.5,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                            decoration: InputDecoration(
                              border: InputBorder.none,
                              hintText:
                                  'Edit the transcript here.\n\nFormat each line as: Speaker: text',
                              hintStyle: TextStyle(
                                color: muted.withValues(alpha: 0.6),
                                height: 1.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
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
}

enum _EditorExitAction { save, discard, cancel }

class _EditorIconButton extends StatelessWidget {
  const _EditorIconButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: (isDark ? Colors.white : Colors.black)
                .withValues(alpha: enabled ? 0.07 : 0.03),
            border: Border.all(
              color: (isDark ? Colors.white : Colors.black)
                  .withValues(alpha: enabled ? 0.12 : 0.06),
            ),
          ),
          child: Icon(
            icon,
            size: 20,
            color: fg.withValues(alpha: enabled ? 0.92 : 0.35),
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, this.accent});

  final String label;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final color = accent ?? (isDark ? Colors.white : const Color(0xFF333344));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color.withValues(alpha: 0.95),
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}
