import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../l10n/strings.dart';

/// First-launch screen.
///
/// It exists for one reason: the people who come back to this kind of app after
/// years away should see, in three seconds, that this is the old workflow with
/// the sharp edges filed off - not a tutorial they have to sit through.
class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = paletteOf(context);

    return Scaffold(
      backgroundColor: p.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 3),
              Center(
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    final t = Curves.easeOutCubic.transform(
                      _controller.value.clamp(0.0, 1.0),
                    );
                    return Opacity(
                      opacity: t,
                      child: Transform.translate(
                        offset: Offset(0, 24 * (1 - t)),
                        child: const _DancingStickman(),
                      ),
                    );
                  },
                ),
              ),
              const Spacer(flex: 2),
              Center(
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    final t = Curves.easeOut.transform(
                      ((_controller.value - 0.3) / 0.7).clamp(0.0, 1.0),
                    );
                    return Opacity(
                      opacity: t,
                      child: Transform.translate(
                        offset: Offset(0, 16 * (1 - t)),
                        child: Column(
                          children: [
                            Text(
                              s.t('introTitle'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -1,
                                color: p.text,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              s.t('introSubtitle'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 16,
                                color: p.textDim,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 24),
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final t = Curves.easeOut.transform(
                    ((_controller.value - 0.55) / 0.45).clamp(0.0, 1.0),
                  );
                  return Opacity(
                    opacity: t,
                    child: Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: p.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: p.border),
                      ),
                      child: Text(
                        s.t('introBody'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14.5,
                          height: 1.5,
                          color: p.textDim,
                        ),
                      ),
                    ),
                  );
                },
              ),
              const Spacer(flex: 2),
              FilledButton(
                onPressed: widget.onDone,
                child: Text(s.t('introStart')),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: widget.onDone,
                child: Text(
                  s.t('introSkip'),
                  style: TextStyle(color: p.textDim),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// A stick figure doing a little victory pose, drawn rather than shipped as an
/// asset so it stays crisp at any density.
class _DancingStickman extends StatefulWidget {
  const _DancingStickman();

  @override
  State<_DancingStickman> createState() => _DancingStickmanState();
}

class _DancingStickmanState extends State<_DancingStickman>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return SizedBox(
      width: 200,
      height: 200,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          final bob = math.sin(t * math.pi * 2) * 4;
          final armUp = math.sin(t * math.pi * 2) * 14;

          return CustomPaint(
            painter: _StickPainter(
              bob: bob,
              armLift: armUp,
              color: p.text,
              accent: p.accent,
            ),
          );
        },
      ),
    );
  }
}

class _StickPainter extends CustomPainter {
  _StickPainter({
    required this.bob,
    required this.armLift,
    required this.color,
    required this.accent,
  });

  final double bob;
  final double armLift;
  final Color color;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final headY = 46 + bob;
    final shoulderY = 74 + bob;
    final hipY = 126 + bob;

    final stroke = Paint()
      ..color = color
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Head
    canvas.drawCircle(Offset(cx, headY), 16, stroke);

    // Torso
    canvas.drawLine(Offset(cx, shoulderY), Offset(cx, hipY), stroke);

    // Arms, one raised
    canvas.drawLine(
      Offset(cx, shoulderY),
      Offset(cx - 30, shoulderY + 26 - armLift),
      stroke,
    );
    canvas.drawLine(
      Offset(cx, shoulderY),
      Offset(cx + 30, shoulderY + 26 + armLift),
      stroke,
    );

    // Legs
    canvas.drawLine(Offset(cx, hipY), Offset(cx - 22, 178 + bob), stroke);
    canvas.drawLine(Offset(cx, hipY), Offset(cx + 22, 178 + bob), stroke);

    // Motion ticks, so the pose reads as movement rather than a still.
    if (armLift > 4) {
      final tick = Paint()
        ..color = accent
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(cx + 44, shoulderY + 6 - armLift),
        Offset(cx + 52, shoulderY - 2 - armLift),
        tick,
      );
      canvas.drawLine(
        Offset(cx + 52, shoulderY + 14 - armLift),
        Offset(cx + 44, shoulderY + 8 - armLift),
        tick,
      );
    }
  }

  @override
  bool shouldRepaint(_StickPainter old) =>
      old.bob != bob || old.armLift != armLift || old.color != color;
}
