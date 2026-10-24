import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/ui/shared/app_feedback.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/app_strings.dart';

class ChatBodyLayout extends StatefulWidget {
  const ChatBodyLayout({
    super.key,
    required this.inbox,
    required this.wide,
    required this.history,
    required this.composer,
    this.compactComposer = false,
  });
  final InboxController inbox;
  final bool wide;
  final bool compactComposer;
  final Widget history, composer;

  @override
  State<ChatBodyLayout> createState() => _ChatBodyLayoutState();
}

class _ChatBodyLayoutState extends State<ChatBodyLayout> {
  double? _fraction;
  Future<void> _save(double fraction) async {
    if (!widget.inbox.store.loaded) return;
    try {
      await widget.inbox.setComposerFraction(fraction);
    } on Object {
      if (mounted) showAppMessage(context, '输入区高度未保存，下次打开后可重新调整');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.wide || widget.compactComposer) {
      return Column(
        children: [
          Expanded(child: widget.history),
          widget.composer,
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final baseMinimum = widget.inbox.store.draftAttachments.isEmpty
            ? 148.0
            : 260.0;
        final minimum =
            baseMinimum +
            (widget.inbox.store.draftQuotes.containsKey(
                  widget.inbox.conversationId,
                )
                ? 32
                : 0);
        final maximum = (height * .65).clamp(minimum, 600.0);
        final fraction = _fraction ?? widget.inbox.store.composerFraction;
        final raw = (height * fraction)
            .clamp(minimum, maximum)
            .clamp(0.0, height * .8);
        final ratio = MediaQuery.devicePixelRatioOf(context);
        final editorHeight = (raw * ratio).roundToDouble() / ratio;
        return Column(
          children: [
            Expanded(child: widget.history),
            SizedBox(
              height: editorHeight,
              child: Stack(
                children: [
                  Positioned.fill(child: widget.composer),
                  Positioned(
                    top: 0,
                    left: 13,
                    right: 13,
                    height: 9,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeUpDown,
                      child: GestureDetector(
                        key: const ValueKey('composer-resize-handle'),
                        behavior: HitTestBehavior.opaque,
                        onDoubleTap: () {
                          setState(() => _fraction = .24);
                          unawaited(_save(.24));
                        },
                        onVerticalDragUpdate: (details) => setState(
                          () => _fraction = height == 0
                              ? fraction
                              : ((editorHeight - details.delta.dy) / height)
                                    .clamp(.18, .6),
                        ),
                        onVerticalDragEnd: (_) =>
                            unawaited(_save(_fraction ?? fraction)),
                        child: Tooltip(
                          message: tr(context, '拖动调整输入区高度，双击恢复'),
                          child: Center(
                            child: Container(
                              width: 32,
                              height: 3,
                              decoration: BoxDecoration(
                                color: ChatPalette.of(context).divider,
                                borderRadius: AppCorners.border,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
