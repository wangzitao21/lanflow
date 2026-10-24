import 'package:flutter/material.dart';

abstract final class AppMotion {
  static Duration duration(BuildContext context, [int milliseconds = 180]) =>
      MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : Duration(milliseconds: milliseconds);

  static const curve = Curves.easeOutCubic;
}

/// Replaces content immediately and animates only the incoming surface.
/// Outgoing pages never retain duplicate focus nodes or intercept new input.
class PageReveal extends StatefulWidget {
  const PageReveal({
    super.key,
    required this.identity,
    required this.child,
    this.enabled = true,
  });
  final Object identity;
  final Widget child;
  final bool enabled;

  @override
  State<PageReveal> createState() => _PageRevealState();
}

class _PageRevealState extends State<PageReveal>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(vsync: this, value: 1);
  late final _curve = CurvedAnimation(
    parent: _animation,
    curve: AppMotion.curve,
  );

  @override
  void didUpdateWidget(PageReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      _animation.duration = widget.enabled
          ? AppMotion.duration(context)
          : Duration.zero;
      _animation.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _curve,
    child: SlideTransition(
      position: Tween(
        begin: const Offset(.018, 0),
        end: Offset.zero,
      ).animate(_curve),
      child: widget.child,
    ),
  );
}
