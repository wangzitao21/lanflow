import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:lanflow/ui/shared/motion.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/app_strings.dart';

class MessageAction {
  const MessageAction(
    this.value,
    this.label,
    this.icon, {
    this.destructive = false,
  });
  final String value;
  final String label;
  final IconData icon;
  final bool destructive;
}

/// A short, cancellable hold; scrolling still wins the gesture arena.
class MessageHold extends StatelessWidget {
  const MessageHold({super.key, required this.child, required this.onHold});
  final Widget child;
  final void Function(Offset, Rect) onHold;
  @override
  Widget build(BuildContext context) => Builder(
    builder: (anchor) => RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                duration: const Duration(milliseconds: 350),
              ),
              (recognizer) => recognizer.onLongPressStart = (event) {
                final box = anchor.findRenderObject()! as RenderBox;
                onHold(
                  event.globalPosition,
                  box.localToGlobal(Offset.zero) & box.size,
                );
              },
            ),
      },
      child: child,
    ),
  );
}

Future<String?> showMessageActions({
  required BuildContext context,
  required Rect anchor,
  required List<MessageAction> actions,
  Key menuKey = const ValueKey('message-action-palette'),
  String barrierLabel = '关闭消息操作',
  bool animate = true,
  bool preserveFocus = false,
}) {
  final fullScreen = MediaQuery.sizeOf(context);
  final screen = Size(
    fullScreen.width,
    fullScreen.height - MediaQuery.viewInsetsOf(context).bottom,
  );
  final palette = ChatPalette.of(context);
  final destructive = Theme.of(context).colorScheme.error;
  final padding = MediaQuery.paddingOf(context);
  var labelWidth = 0.0;
  var rowHeight = 48.0;
  for (final action in actions) {
    final painter = TextPainter(
      text: TextSpan(
        text: tr(context, action.label),
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(fontSize: AppTypography.secondary),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    labelWidth = math.max(labelWidth, painter.width);
    rowHeight = math.max(rowHeight, painter.height + 20);
    painter.dispose();
  }
  final width = math.min(screen.width - 24, math.max(152.0, labelWidth + 54));
  final separators = actions.skip(1).where((a) => a.destructive).length;
  final height = math.min(
    actions.length * rowHeight + 10 + separators * 9,
    screen.height - padding.vertical - 16,
  );
  final left = (anchor.center.dx - width / 2).clamp(
    12.0,
    screen.width - width - 12,
  );
  final above = anchor.top >= padding.top + height + 16;
  final top = (above ? anchor.top - height - 8 : anchor.bottom + 8).clamp(
    padding.top + 8,
    math.max(padding.top + 8, screen.height - padding.bottom - height - 8),
  );
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: tr(context, barrierLabel),
    barrierColor: Colors.transparent,
    requestFocus: !preserveFocus,
    transitionDuration: animate
        ? AppMotion.duration(context, 110)
        : Duration.zero,
    pageBuilder: (context, _, _) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.pop(context),
      },
      child: Focus(
        autofocus: !preserveFocus,
        canRequestFocus: !preserveFocus,
        child: Stack(
          children: [
            Positioned(
              left: left,
              top: top.toDouble(),
              width: width,
              child: Material(
                key: menuKey,
                color: palette.menu,
                elevation: 6,
                shadowColor: Colors.black38,
                shape: RoundedRectangleBorder(
                  borderRadius: AppCorners.border,
                  side: BorderSide(color: palette.divider),
                ),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: height),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final (index, action) in actions.indexed) ...[
                            if (index > 0 && action.destructive)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),
                                child: Divider(
                                  height: 1,
                                  color: palette.divider,
                                ),
                              ),
                            Semantics(
                              button: true,
                              child: InkWell(
                                key: ValueKey('touch-menu-${action.value}'),
                                onTap: () =>
                                    Navigator.pop(context, action.value),
                                child: Container(
                                  height: rowHeight,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 13,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        action.icon,
                                        size: 18,
                                        color: action.destructive
                                            ? destructive
                                            : palette.text,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          tr(context, action.label),
                                          style: TextStyle(
                                            fontSize: AppTypography.secondary,
                                            color: action.destructive
                                                ? destructive
                                                : palette.text,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    transitionBuilder: (_, animation, _, child) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position:
            Tween(
              begin: Offset(0, above ? .006 : -.006),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
        child: child,
      ),
    ),
  );
}
