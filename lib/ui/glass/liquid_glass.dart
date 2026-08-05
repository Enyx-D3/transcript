// lib/ui/glass/liquid_glass.dart
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui';
import 'dart:async';
import 'package:flutter/material.dart';
import 'glass_tokens.dart';

class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.borderRadius,
    this.padding,
    this.margin,
    this.blurX,
    this.blurY,
    this.borderWidth,
    this.tintOpacityLight,
    this.tintOpacityDark,
    this.borderOpacityLight,
    this.borderOpacityDark,
    this.shadow = false,
    this.shadowBlur,
    this.shadowOffset,
    this.shadowOpacityLight,
    this.shadowOpacityDark,
    this.onTap,
    this.clipBehavior = Clip.hardEdge,
    this.highlightOpacityLight = GlassTokens.highlightOpacityLight,
    this.highlightOpacityDark = GlassTokens.highlightOpacityDark,

    // ✅ grain
    this.grain = true,
    this.grainOpacityDark = 0.06,
    this.grainOpacityLight = 0.035,
  });

  final Widget child;

  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  final double? blurX;
  final double? blurY;

  final double? borderWidth;

  final double? tintOpacityLight;
  final double? tintOpacityDark;

  final double? borderOpacityLight;
  final double? borderOpacityDark;

  final bool shadow;
  final double? shadowBlur;
  final Offset? shadowOffset;
  final double? shadowOpacityLight;
  final double? shadowOpacityDark;

  final VoidCallback? onTap;
  final Clip clipBehavior;

  final double highlightOpacityLight;
  final double highlightOpacityDark;

  final bool grain;
  final double grainOpacityDark;
  final double grainOpacityLight;

  @override
  Widget build(BuildContext context) {
    final br = borderRadius ?? GlassTokens.radiusCard;
    final bx = blurX ?? GlassTokens.blurSm;
    final by = blurY ?? GlassTokens.blurSm;
    final bw = borderWidth ?? GlassTokens.borderWidth;

    final isDark = GlassTokens.isDark(context);

    final tint = Colors.white.withValues(
      alpha: isDark
          ? (tintOpacityDark ?? GlassTokens.tintPanelDark)
          : (tintOpacityLight ?? GlassTokens.tintPanelLight),
    );

    final border = Colors.white.withValues(
      alpha: isDark
          ? (borderOpacityDark ?? GlassTokens.borderOpacityDark)
          : (borderOpacityLight ?? GlassTokens.borderOpacityLight),
    );

    final shadowColor = Colors.black.withValues(
      alpha: isDark
          ? (shadowOpacityDark ?? GlassTokens.shadowOpacityDark)
          : (shadowOpacityLight ?? GlassTokens.shadowOpacityLight),
    );

    final topHighlight = Colors.white.withValues(
      alpha: isDark ? highlightOpacityDark : highlightOpacityLight,
    );

    final grainOpacity = isDark ? grainOpacityDark : grainOpacityLight;

    Widget glassSurface = Stack(
      fit: StackFit.passthrough,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: tint,
            borderRadius: br,
            border: Border.all(color: border, width: bw),
            boxShadow: shadow
                ? [
                    BoxShadow(
                      blurRadius: shadowBlur ?? GlassTokens.shadowBlur,
                      offset: shadowOffset ?? GlassTokens.shadowOffset,
                      color: shadowColor,
                    ),
                  ]
                : null,
          ),
          child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
        ),

        // ✅ Grain overlay (optimized)
        if (grain)
          Positioned.fill(
            child: IgnorePointer(child: _GlassGrainFast(opacity: grainOpacity)),
          ),

        // Specular top line highlight
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: 1,
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                color: topHighlight,
                borderRadius: BorderRadius.only(
                  topLeft: br.topLeft,
                  topRight: br.topRight,
                ),
              ),
            ),
          ),
        ),
      ],
    );

    final enableBlur = (bx > 0.0 || by > 0.0);

    Widget core = ClipRRect(
      borderRadius: br,
      clipBehavior: clipBehavior,
      child: enableBlur
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: bx, sigmaY: by),
              child: glassSurface,
            )
          : glassSurface,
    );

    if (onTap != null) {
      core = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: core,
      );
    }

    if (margin != null) {
      core = Container(margin: margin, child: core);
    }

    return core;
  }
}

/// Optimized grain:
/// - No FutureBuilder
/// - Image tile cached globally
/// - Cheaper blend mode (softLight) by default
class _GlassGrainFast extends StatelessWidget {
  const _GlassGrainFast({required this.opacity});

  final double opacity;

  static ui.Image? _tile; // cached
  static bool _started = false;

  static void _startWarmup() {
    if (_started) return;
    _started = true;
    // Fire-and-forget generation; first frames show no grain, but no rebuild flicker.
    _makeNoiseTile(size: 128, seed: 1337).then((img) => _tile = img);
  }

  static Future<ui.Image> _makeNoiseTile({
    required int size,
    required int seed,
  }) async {
    final rng = math.Random(seed);
    final bytes = Uint8List(size * size * 4);

    for (int i = 0; i < size * size; i++) {
      final v = 180 + rng.nextInt(76);
      final o = i * 4;
      bytes[o + 0] = v; // R
      bytes[o + 1] = v; // G
      bytes[o + 2] = v; // B
      bytes[o + 3] = 255; // A
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      size,
      size,
      ui.PixelFormat.rgba8888,
      (ui.Image img) => completer.complete(img),
    );
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    _startWarmup();
    final img = _tile;
    if (img == null) return const SizedBox.expand();

    return RepaintBoundary(
      child: CustomPaint(
        painter: _NoiseShaderPainterFast(img, opacity),
        size: Size.infinite,
      ),
    );
  }
}

class _NoiseShaderPainterFast extends CustomPainter {
  _NoiseShaderPainterFast(this.tile, this.opacity);

  final ui.Image tile;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    // Slight scale makes the repetition less visible with less shader pressure.
    final m = Matrix4.identity()..scaleByDouble(0.75, 0.75, 0.75, 0.75);

    final paint = Paint()
      ..filterQuality = FilterQuality.low
      ..shader = ui.ImageShader(
        tile,
        TileMode.repeated,
        TileMode.repeated,
        m.storage,
      )
      // ✅ cheaper than overlay but still “Apple-ish”
      ..blendMode = BlendMode.softLight
      ..color = Color.fromRGBO(255, 255, 255, opacity);

    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _NoiseShaderPainterFast oldDelegate) =>
      oldDelegate.opacity != opacity;
}
