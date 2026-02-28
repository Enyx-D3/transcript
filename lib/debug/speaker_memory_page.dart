// lib/debug/speaker_memory_page.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:transcript/common/app_flushbar.dart';
import 'package:transcript/common/confirm_dialog.dart';
import 'package:transcript/widgets/leading_pill_icon.dart';

import 'speaker_memory.dart';

// ✅ Glass primitives
import '../ui/glass/glass_background.dart';
import '../ui/glass/glass_button.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_chip.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';
import '../ui/glass/liquid_glass.dart';

// ✅ Appbar X button
import '../widgets/icon_pill_button.dart';

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
    if (mounted) setState(() => _loading = true);

    final mem = await SpeakerMemory.instance();
    final map = mem.dumpAll();

    final rows = <_Row>[];
    final jsonMap = <String, List<List<double>>>{};

    map.forEach((name, protos) {
      final count = protos.length;
      final dim = count == 0 ? 0 : protos.first.length;

      rows.add(_Row(name: name, count: count, dim: dim));

      jsonMap[name] =
          protos.map((emb) => emb.map((e) => e.toDouble()).toList()).toList();
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
      message:
          'This will remove every enrolled speaker. This action cannot be undone.',
      confirmText: 'Clear All',
    );

    if (!confirmed) return;

    if (mounted) setState(() => _loading = true);
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
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // keep your “glass on glass” look
      barrierColor: Colors.transparent,
      builder: (_) => _GlassBottomSheet(
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const LeadingPillIcon(icon: Icons.person),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                          color: GlassTokens.fg(context),
                        ),
                      ),
                    ),
                    GlassChip(
                      label: protos.isEmpty
                          ? 'No vectors'
                          : '${protos.length} vectors • dim ${protos.first.length}',
                      icon:
                          protos.isEmpty ? Icons.info_outline : Icons.graphic_eq,
                      onTap: null,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (protos.isNotEmpty)
                  Expanded(
                    child: GlassCard(
                      variant: GlassCardVariant.panel,
                      padding: EdgeInsets.zero,
                      child: ListView.separated(
                        itemCount: protos.length,
                        separatorBuilder: (_, _) =>
                            const GlassDivider(height: 1, thickness: 0.8),
                        itemBuilder: (_, i) {
                          final v = protos[i];
                          return ListTile(
                            leading:
                                const LeadingPillIcon(icon: Icons.graphic_eq),
                            title: Text(
                              'Vector ${i + 1}',
                              style: TextStyle(
                                color: GlassTokens.fg(context),
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            subtitle: Text(
                              'dim = ${v.length}',
                              style: TextStyle(
                                color: GlassTokens.muted(context),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: Center(
                      child: Text(
                        'No vectors stored for this speaker.',
                        style: TextStyle(
                          color: GlassTokens.muted(context),
                          fontWeight: FontWeight.w700,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: GlassBackground(
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ---------- App bar (NO card) ----------
                      Row(
                        children: [
                          IconPillButton(
                            tooltip: 'Close',
                            icon: Icons.close,
                            onTap: () => Navigator.of(context).pop(),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Speaker memory',
                                  style: theme.textTheme.headlineSmall?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -0.2,
                                    color: GlassTokens.fg(context),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Enrolled voice profiles',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: GlassTokens.muted(context),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconPillButton(
                            tooltip: 'Copy JSON',
                            icon: Icons.content_copy,
                            onTap: _copyJson,
                          ),
                          const SizedBox(width: 8),
                          IconPillButton(
                            tooltip: 'Clear all',
                            icon: Icons.delete_sweep,
                            onTap: _clearAll,
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),

                      // ---------- Content (scrollable) ----------
                      Expanded(
                        child: RefreshIndicator.adaptive(
                          onRefresh: _load,
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
                            children: [
                              GlassCard(
                                variant: GlassCardVariant.panel,
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          'Profiles',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w900,
                                            color: GlassTokens.fg(context),
                                          ),
                                        ),
                                        const Spacer(),
                                        GlassChip(
                                          label: '${_rows.length}',
                                          icon: Icons.people_alt_outlined,
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),

                                    if (_rows.isEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: Text(
                                          'No profiles saved yet.',
                                          style: TextStyle(
                                            color: GlassTokens.muted(context),
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      )
                                    else
                                      LayoutBuilder(
                                        builder: (ctx, c) {
                                          final maxH =
                                              MediaQuery.of(context).size.height *
                                                  0.48;

                                          return ConstrainedBox(
                                            constraints:
                                                BoxConstraints(maxHeight: maxH),
                                            // ✅ NOTE: keep just ONE card surface here
                                            child: LiquidGlass(
                                              borderRadius:
                                                  BorderRadius.circular(18),
                                              padding: EdgeInsets.zero,
                                              shadow: false,
                                              blurX: 0,
                                              blurY: 0,
                                              grain: false,
                                              tintOpacityDark: 0.035,
                                              tintOpacityLight: 0.030,
                                              borderOpacityDark: 0.16,
                                              borderOpacityLight: 0.20,
                                              child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(18),
                                                child: ListView.separated(
                                                  itemCount: _rows.length,
                                                  separatorBuilder: (_, _) =>
                                                      const GlassDivider(
                                                    height: 1,
                                                    thickness: 0.8,
                                                    indent: 14,
                                                    endIndent: 14,
                                                  ),
                                                  itemBuilder: (_, i) =>
                                                      _ProfileRow(
                                                    name: _rows[i].name,
                                                    meta:
                                                        'vectors: ${_rows[i].count} • dim: ${_rows[i].dim}',
                                                    onOpen: () => _openVectors(
                                                      _rows[i].name,
                                                    ),
                                                    onDelete: () => _delete(
                                                      _rows[i].name,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),

                                    const SizedBox(height: 12),

                                    // Quick actions row
                                    Row(
                                      children: [
                                        Expanded(
                                          child: GlassButton(
                                            label: 'Copy JSON',
                                            icon: Icons.content_copy,
                                            kind: GlassButtonKind.secondary,
                                            onPressed: _copyJson,
                                            // ✅ your new API: default no inner chrome
                                            innerChrome: false,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: GlassButton(
                                            label: 'Clear All',
                                            icon: Icons.delete_sweep,
                                            kind: GlassButtonKind.primary,
                                            onPressed: _clearAll,
                                            innerChrome: false,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
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
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
        child: Row(
          children: [
            const LeadingPillIcon(icon: Icons.person),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: GlassTokens.fg(context),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: GlassTokens.muted(context),
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _GlassIconButton(
              tooltip: 'Delete',
              icon: Icons.delete_outline,
              onTap: onDelete,
              size: 38,
            ),
          ],
        ),
      ),
    );
  }
}

/// Icon-only glass button (internal; you still use IconPillButton for appbar)
class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.size = 40,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context);

    return Tooltip(
      message: tooltip,
      child: LiquidGlass(
        borderRadius: BorderRadius.circular(999),
        padding: EdgeInsets.zero,
        shadow: false,
        // ✅ crisp controls (tint-only) to avoid muddy stacking on glass pages
        blurX: 0,
        blurY: 0,
        grain: false,
        tintOpacityLight: 0.055,
        tintOpacityDark: 0.070,
        borderOpacityLight: 0.20,
        borderOpacityDark: 0.16,
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(child: Icon(icon, color: fg, size: 18)),
        ),
      ),
    );
  }
}



class _GlassBottomSheet extends StatelessWidget {
  const _GlassBottomSheet({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final blur = isDark ? GlassTokens.blurLg : 22.0;

    return LiquidGlass(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      blurX: blur,
      blurY: blur,
      shadow: true,
      shadowBlur: 36,
      shadowOffset: const Offset(0, -8),
      shadowOpacityDark: 0.22,
      shadowOpacityLight: 0.10,
      tintOpacityLight: 0.035,
      tintOpacityDark: 0.045,
      borderOpacityLight: 0.22,
      borderOpacityDark: 0.16,
      child: child,
    );
  }
}

class _Row {
  const _Row({required this.name, required this.count, required this.dim});
  final String name;
  final int count;
  final int dim;
}
