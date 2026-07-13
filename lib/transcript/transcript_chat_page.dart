// lib/transcript/transcript_chat_page.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:transcript/widgets/icon_pill_button.dart';

import '../objectbox/objectbox_store.dart';
import '../objectbox/entities.dart';
import '../objectbox.g.dart';

import '../llm_service.dart' show LLMService, qwenMaxContext;
import '../qwen_model_service.dart';
import '../moonshine_service.dart' show ModelProgress;

import '../report/report_dialog.dart';
import '../report/report_service.dart';
import '../common/app_flushbar.dart';

// ✅ NEW (for clickable "Download model" banner)
import '../model_picker_page.dart';

// ✅ Glass primitives
import '../ui/glass/glass_background.dart';
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_button.dart';
import '../ui/glass/glass_chip.dart';
import '../ui/glass/glass_dock.dart';
import '../ui/glass/glass_tokens.dart';

class TranscriptChatPage extends StatefulWidget {
  const TranscriptChatPage({super.key, required this.transcriptId});

  final int transcriptId;

  @override
  State<TranscriptChatPage> createState() => _TranscriptChatPageState();
}

class _TranscriptChatPageState extends State<TranscriptChatPage> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  final QwenModelService _qwenService = QwenModelService();
  StreamSubscription<ModelProgress>? _qwenSub;

  final ReportService _reportService = const ReportService(
    baseUrl: 'https://enyx.app',
  );

  bool _initializing = true;
  bool _modelAvailable = false;
  String? _modelPath;

  bool _sending = false;
  String? _error;

  List<TranscriptChatMessageEntity> _messages = const [];

  StreamSubscription<Map<String, dynamic>>? _streamSub;

  // ✅ throttling: don’t write to DB too often while streaming
  int _lastPersistMs = 0;

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _initModelState();
  }

  @override
  void dispose() {
    _qwenSub?.cancel();
    _streamSub?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // =========================
  // Helpers
  // =========================

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      final to = _scrollCtrl.position.maxScrollExtent + 220;
      if (!animate) {
        _scrollCtrl.jumpTo(to);
      } else {
        _scrollCtrl.animateTo(
          to,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _cleanModelOutput(String s) {
    var out = s.trim();

    // Remove any Qwen template tokens that leaked into the output
    out = out.replaceAll('<|im_end|>', '');
    out = out.replaceAll('<|im_start|>assistant', '');
    out = out.replaceAll('<|im_start|>', '');

    // If the model echoed "Answer:"
    if (out.toLowerCase().startsWith('answer:')) {
      out = out.substring('answer:'.length).trim();
    }

    return out.trim();
  }

  bool _shouldPersistNow() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastPersistMs >= 450) {
      _lastPersistMs = now;
      return true;
    }
    return false;
  }

  // =========================
  // Load & model state
  // =========================

  Future<void> _loadMessages() async {
    final obx = ObjectBox.I;
    final qb = obx.chatMessages.query(
      TranscriptChatMessageEntity_.transcriptId.equals(widget.transcriptId),
    )..order(TranscriptChatMessageEntity_.createdAt);
    final q = qb.build();
    final rows = q.find();
    q.close();

    if (!mounted) return;
    setState(() => _messages = rows);
    _scrollToBottom();
  }

  Future<void> _initModelState() async {
    final exists = await _qwenService.isModelDownloaded();
    final path = await _qwenService.modelFilePath();

    if (!mounted) return;
    setState(() {
      _initializing = false;
      _modelAvailable = exists;
      _modelPath = exists ? path : null;
    });

    _qwenSub?.cancel();
    _qwenSub = _qwenService.progress.listen((p) async {
      if (!mounted) return;
      final finishedOk =
          !p.downloading && p.error == null && p.total == 1 && p.received == 1;
      if (finishedOk) {
        final ok = await _qwenService.isModelDownloaded();
        if (!mounted) return;
        if (ok) {
          final newPath = await _qwenService.modelFilePath();
          if (!mounted) return;
          setState(() {
            _modelAvailable = true;
            _modelPath = newPath;
          });
        }
      }
    });
  }

  Future<void> _openModelPicker() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ModelPickerPage()));
    await _initModelState(); // refresh model availability on return
  }

  // =========================
  // Send question (STREAMING UI)
  // =========================

  Future<void> _send() async {
    final question = _inputCtrl.text.trim();
    if (question.isEmpty || _sending) return;

    if (!_modelAvailable || _modelPath == null) {
      setState(() {
        _error = 'Please download the Qwen model first (Model picker).';
      });
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
    });

    // Cancel any previous stream (safety)
    await _streamSub?.cancel();
    _streamSub = null;

    final obx = ObjectBox.I;

    // 1) Persist user message
    obx.chatMessages.put(
      TranscriptChatMessageEntity(
        transcriptId: widget.transcriptId,
        isUser: true,
        text: question,
        createdAt: DateTime.now(),
      ),
    );

    _inputCtrl.clear();

    // 2) Insert placeholder assistant message (for live streaming)
    final placeholder = TranscriptChatMessageEntity(
      transcriptId: widget.transcriptId,
      isUser: false,
      text: '…',
      createdAt: DateTime.now(),
    );
    final placeholderId = obx.chatMessages.put(placeholder);

    await _loadMessages(); // show user msg + placeholder bubble

    try {
      // 3) Build transcript context
      final qbTurns = obx.turns.query(
        TranscriptTurnEntity_.transcript.equals(widget.transcriptId),
      )..order(TranscriptTurnEntity_.startSec);
      final qTurns = qbTurns.build();
      final turns = qTurns.find();
      qTurns.close();

      final buf = StringBuffer();
      for (final u in turns) {
        final txt = u.text.trim();
        if (txt.isEmpty) continue;
        buf.writeln('${u.speakerLabel}: $txt');
      }
      final transcriptText = buf.toString().trim();

      if (transcriptText.isEmpty) {
        throw Exception('Transcript has no segments yet.');
      }

      // 4) Stream QA (update UI live)
      String latestFullText = '';
      String accum = '';

      final stream = LLMService.qaOnTranscript(
        transcript: transcriptText,
        question: question,
        modelPath: _modelPath!,
        maxTokens: 512,
        temperature: 0.3,
        contextSize: qwenMaxContext,
      );

      final doneCompleter = Completer<void>();

      _streamSub = stream.listen(
        (evt) {
          final full = (evt['full_text'] ?? '') as String;
          final newText = (evt['new_text'] ?? '') as String;
          final done = evt['done'] == true;

          if (full.isNotEmpty) {
            latestFullText = full;
          } else if (newText.isNotEmpty) {
            accum += newText;
          }

          final raw = latestFullText.isNotEmpty ? latestFullText : accum;
          final cleaned = _cleanModelOutput(raw);

          // ✅ update local UI immediately
          if (mounted) {
            setState(() {
              final idx = _messages.indexWhere((m) => m.id == placeholderId);
              if (idx != -1) {
                _messages[idx].text = cleaned.isEmpty ? '…' : cleaned;
              }
            });
            _scrollToBottom();
          }

          // ✅ persist occasionally (throttled)
          if (_shouldPersistNow()) {
            final msg = obx.chatMessages.get(placeholderId);
            if (msg != null) {
              msg.text = cleaned.isEmpty ? '…' : cleaned;
              obx.chatMessages.put(msg);
            }
          }

          if (done && !doneCompleter.isCompleted) {
            doneCompleter.complete();
          }
        },
        onError: (err, st) {
          if (!doneCompleter.isCompleted) {
            doneCompleter.completeError(err, st);
          }
        },
      );

      await doneCompleter.future;

      // 5) Finalize + persist final clean text
      var finalText = latestFullText.isNotEmpty ? latestFullText : accum;
      finalText = _cleanModelOutput(finalText);

      if (finalText.trim().isEmpty) {
        finalText = "I don't know based on the transcript.";
      }

      final msg = obx.chatMessages.get(placeholderId);
      if (msg != null) {
        msg.text = finalText;
        obx.chatMessages.put(msg);
      }

      await _loadMessages();
    } catch (e) {
      // mark placeholder as error
      final msg = obx.chatMessages.get(placeholderId);
      if (msg != null) {
        msg.text = 'Failed to get answer.';
        obx.chatMessages.put(msg);
      }

      if (!mounted) return;
      setState(() {
        _error = 'Failed to get AI answer: $e';
      });
      await AppFlushbar.error(context, message: 'Failed to get answer.');
    } finally {
      await _streamSub?.cancel();
      _streamSub = null;

      if (!mounted) return;
      setState(() => _sending = false);
    }
  }

  // =========================
  // UI helpers
  // =========================

  Future<void> _copyText(String text) async {
    final t = text.trim();
    if (t.isEmpty) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Nothing to copy.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: t));
    if (!mounted) return;
    await AppFlushbar.success(context, message: 'Copied.');
  }

  Future<void> _reportAiMessage(TranscriptChatMessageEntity m) async {
    final meta = <String, dynamic>{
      'source': 'transcript_chat',
      'transcriptId': widget.transcriptId,
      'messageId': m.id,
      'createdAt': m.createdAt.toIso8601String(),
    };

    await showReportDialog(
      outerContext: context,
      responseText: m.text,
      meta: meta,
      sendReport: ({
        required String reason,
        required String note,
        required String response,
        Map<String, dynamic>? meta,
      }) {
        return _reportService.sendReport(
          reason: reason,
          note: note,
          response: response,
          meta: meta,
        );
      },
    );
  }

  // ✅ NEW: reuse the same “perfect capsule” pill logic everywhere
  Widget _metaPill(String text, {Color? accent, IconData? icon}) {
    final c = accent;
    final tl = c != null ? 0.055 : 0.050;
    final td = c != null ? 0.075 : 0.070;
    final bl = c != null ? 0.24 : 0.20;
    final bd = c != null ? 0.20 : 0.16;

    final radius = BorderRadius.circular(999);

    return ClipRRect(
      borderRadius: radius,
      child: LiquidGlass(
        borderRadius: radius,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shadow: false,
        // chips: crisp (avoid double blur)
        blurX: 0,
        blurY: 0,
        grain: false,
        tintOpacityLight: tl,
        tintOpacityDark: td,
        borderOpacityLight: bl,
        borderOpacityDark: bd,
        child: SizedBox(
          height: 32,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 14,
                  color: (c ?? Colors.white).withValues(alpha: 0.95),
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: (c ?? Colors.white).withValues(alpha: 0.95),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBubble(TranscriptChatMessageEntity m) {
    final isUser = m.isUser;

    final align = isUser ? Alignment.centerRight : Alignment.centerLeft;

    // ✅ Differentiated “glass”
    final double userTintDark = 0.085;
    final double userTintLight = 0.070;
    final double aiTintDark = 0.28;
    final double aiTintLight = 0.024;

    final double userBorderDark = 0.18;
    final double userBorderLight = 0.22;
    final double aiBorderDark = 0.14;
    final double aiBorderLight = 0.18;

    final isDark = GlassTokens.isDark(context);

    final tint = isUser
        ? (isDark ? userTintDark : userTintLight)
        : (isDark ? aiTintDark : aiTintLight);

    final border = isUser
        ? (isDark ? userBorderDark : userBorderLight)
        : (isDark ? aiBorderDark : aiBorderLight);

    return Align(
      alignment: align,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment:
                isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              // ✅ FIX: ensure bubble corners clip perfectly (prevents “not fully round”)
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: LiquidGlass(
                  borderRadius: BorderRadius.circular(18),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  blurX: isUser ? 14 : 22,
                  blurY: isUser ? 14 : 22,
                  shadow: false,
                  tintOpacityDark: tint,
                  tintOpacityLight: tint,
                  borderOpacityDark: border,
                  borderOpacityLight: border,
                  child: Text(
                    m.text,
                    style: TextStyle(
                      color: GlassTokens.fg(context, alpha: 0.94),
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),

              // ✅ Actions for AI only (glass chips)
              if (!isUser)
                Padding(
                  padding: const EdgeInsets.only(top: 8, left: 2),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      GlassChip(
                        label: 'COPY',
                        icon: Icons.copy,
                        onTap: () => _copyText(m.text),
                      ),
                      GlassChip(
                        label: 'REPORT',
                        icon: Icons.flag_outlined,
                        onTap: () => _reportAiMessage(m),
                        tintDark: 0.055,
                        tintLight: 0.045,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modelBanner() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: GlassCard(
        variant: GlassCardVariant.panel,
        onTap: _openModelPicker,
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              Icons.smart_toy_outlined,
              color: GlassTokens.muted(context, alpha: 0.82),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Model required to ask new questions.\nTap to open Model Download.',
                style: TextStyle(
                  color: GlassTokens.muted(context, alpha: 0.78),
                  height: 1.25,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 10),
            GlassButton(
              label: 'DOWNLOAD',
              icon: Icons.download,
              expand: false,
              kind: GlassButtonKind.primary,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              onPressed: _openModelPicker,
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorBanner(String msg) {
    final radius = BorderRadius.circular(18);
    final isDark = GlassTokens.isDark(context);

    // ✅ UPDATED: use LiquidGlass for the error surface (still matches your glass)
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: ClipRRect(
        borderRadius: radius,
        child: LiquidGlass(
          borderRadius: radius,
          padding: const EdgeInsets.all(14),
          shadow: false,
          blurX: isDark ? 16 : 12,
          blurY: isDark ? 16 : 12,
          grain: false,
          tintOpacityDark: 0.055,
          tintOpacityLight: 0.045,
          borderOpacityDark: 0.20,
          borderOpacityLight: 0.24,
          child: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  msg,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _composer(bool canSend) {
    return GlassDock(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      innerPadding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputCtrl,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.newline,
              cursorColor: GlassTokens.fg(context, alpha: 0.9),
              style: TextStyle(
                color: GlassTokens.fg(context, alpha: 0.92),
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                hintText: 'Ask about this transcript…',
                hintStyle: TextStyle(
                  color: GlassTokens.muted(context, alpha: 0.55),
                  fontWeight: FontWeight.w700,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              onChanged: (_) {
                // ensures send button enabling updates when user types
                if (mounted) setState(() {});
              },
            ),
          ),
          const SizedBox(width: 10),
          GlassButton(
            label: _sending ? 'SENDING' : 'SEND',
            icon: Icons.send,
            expand: false,
            kind: GlassButtonKind.primary,
            loading: _sending,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            onPressed: canSend ? _send : null,
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _glassAppBar() {
    final fg = GlassTokens.fg(context, alpha: 0.92);
  
    return AppBar(
      automaticallyImplyLeading: false,
      titleSpacing: 12,
      backgroundColor: Colors.transparent,
      elevation: 0,
      flexibleSpace: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              IconPillButton(
                tooltip: 'Back',
                icon: Icons.arrow_back,
                onTap: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: 10),
              Text(
                'Ask AI',
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.2,
                  fontSize: 20,
                ),
              ),
              const Spacer(),
              if (_sending)
                // ✅ UPDATED: glass pill instead of plain text
                _metaPill('thinking…', accent: null, icon: Icons.sync),
              if (_sending) const SizedBox(width: 2),
              if (!_sending)
                const SizedBox(width: 2), // keep right padding stable
            ],
          ),
        ),
      ),
      toolbarHeight: 68,
    );
  }

  // =========================
  // Build
  // =========================

  @override
  Widget build(BuildContext context) {
    final hasModel = _modelAvailable && _modelPath != null;
    final hasText = _inputCtrl.text.trim().isNotEmpty;
    final canSend = hasModel && !_sending && hasText;

    if (_initializing) {
      return Scaffold(
        extendBodyBehindAppBar: true,
        appBar: _glassAppBar(),
        body: const GlassBackground(
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: _glassAppBar(),
      body: GlassBackground(
        child: Column(
          children: [
            const SizedBox(height: 78), // space for glass app bar
            if (!_modelAvailable) _modelBanner(),
            if (_error != null) _errorBanner(_error!),
            Expanded(
              child: ListView.builder(
                controller: _scrollCtrl,
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                itemCount: _messages.length,
                itemBuilder: (ctx, i) => _buildBubble(_messages[i]),
              ),
            ),
            _composer(canSend),
          ],
        ),
      ),
    );
  }
}
