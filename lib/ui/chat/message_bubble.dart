import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.outgoing,
    required this.child,
    this.textCursor = false,
    this.tailOffset = 20,
    this.backgroundColor,
    this.contentPadding = ChatMetrics.bubblePadding,
    this.minHeight = 40,
  });
  final bool outgoing, textCursor;
  final Widget child;
  final double tailOffset;
  final Color? backgroundColor;
  final EdgeInsetsGeometry contentPadding;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final palette = ChatPalette.of(context);
    final fill =
        backgroundColor ?? (outgoing ? palette.outgoing : palette.surface);
    return MouseRegion(
      cursor: textCursor ? SystemMouseCursors.text : MouseCursor.defer,
      child: Container(
        constraints: BoxConstraints(minHeight: minHeight),
        decoration: ShapeDecoration(
          color: fill,
          shape: MessageBubbleBorder(
            outgoing: outgoing,
            tailOffset: tailOffset,
            side: BorderSide(
              color: outgoing && backgroundColor == null
                  ? fill
                  : palette.divider,
              width: 1,
            ),
          ),
        ),
        padding: contentPadding.add(
          EdgeInsets.only(
            left: outgoing ? 0 : ChatMetrics.bubbleTailWidth,
            right: outgoing ? ChatMetrics.bubbleTailWidth : 0,
          ),
        ),
        child: child,
      ),
    );
  }
}

class MessageBubbleBorder extends ShapeBorder {
  const MessageBubbleBorder({
    required this.outgoing,
    this.side = BorderSide.none,
    this.tailOffset = 20,
  });
  final bool outgoing;
  final BorderSide side;
  final double tailOffset;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  Path _outline(Rect rect) {
    final tail = ChatMetrics.bubbleTailWidth;
    final body = Rect.fromLTRB(
      rect.left + (outgoing ? 0 : tail),
      rect.top,
      rect.right - (outgoing ? tail : 0),
      rect.bottom,
    ).deflate(side.width / 2);
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          body,
          const Radius.circular(ChatMetrics.bubbleRadius),
        ),
      );
    final center = rect.top + math.min(tailOffset, rect.height / 2);
    final edge = outgoing ? body.right : body.left;
    final tip = outgoing
        ? rect.right - side.width / 2
        : rect.left + side.width / 2;
    final halfTail = math.min(
      5.0,
      math.max(0.0, (rect.height - side.width) / 2),
    );
    final pointer = Path()
      ..moveTo(edge, center - halfTail)
      ..lineTo(tip, center)
      ..lineTo(edge, center + halfTail)
      ..close();
    return Path.combine(PathOperation.union, path, pointer);
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      _outline(rect);
  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _outline(rect.deflate(side.width));
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style != BorderStyle.none && side.width > 0) {
      canvas.drawPath(_outline(rect), side.toPaint());
    }
  }

  @override
  ShapeBorder scale(double t) => MessageBubbleBorder(
    outgoing: outgoing,
    side: side.scale(t),
    tailOffset: tailOffset,
  );
}
