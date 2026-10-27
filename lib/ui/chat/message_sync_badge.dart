import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';

class MessageSyncBadge extends StatelessWidget {
  const MessageSyncBadge({
    super.key,
    required this.inbox,
    required this.entry,
    required this.outgoing,
    required this.onPressed,
    required this.child,
  });
  final InboxController inbox;
  final InboxEntry entry;
  final bool outgoing;
  final VoidCallback onPressed;
  final Widget child;
  static const diameter = 16.0;
  static const hitSize = 32.0;
  static const completeColor = Color(0xFF229A62);
  static const pendingColor = Color(0xFFF2BF45);

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      Padding(
        padding: EdgeInsets.only(
          right: hitSize / 2 - (outgoing ? ChatMetrics.bubbleTailWidth : 0),
          bottom: hitSize / 2,
        ),
        child: KeyedSubtree(
          key: ValueKey('message-badge-content-${entry.item.id}'),
          child: child,
        ),
      ),
      Positioned(
        right: 0,
        bottom: 0,
        child: ValueListenableBuilder<int>(
          valueListenable: inbox.activity,
          builder: (context, _, _) {
            final complete =
                inbox.conflictFor(entry.item.id) == null &&
                inbox
                    .copyDetails(entry)
                    .every((detail) => detail.state == CopyState.complete);
            return Semantics(
              button: true,
              label: tr(context, complete ? '已同步' : '同步未完成'),
              child: Tooltip(
                message: tr(context, '同步详情'),
                child: Material(
                  color: Colors.transparent,
                  child: InkResponse(
                    key: ValueKey('copy-status-${entry.item.id}'),
                    onTap: onPressed,
                    radius: hitSize / 2,
                    splashColor: Colors.transparent,
                    highlightColor: Colors.transparent,
                    child: SizedBox.square(
                      dimension: hitSize,
                      child: Center(
                        child: Container(
                          key: ValueKey('sync-badge-${entry.item.id}'),
                          width: diameter,
                          height: diameter,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: complete ? completeColor : pendingColor,
                            border: Border.all(
                              color: ChatPalette.of(context).canvas,
                              width: 1.2,
                            ),
                          ),
                          child: Icon(
                            complete
                                ? Icons.check_rounded
                                : Icons.priority_high_rounded,
                            color: complete
                                ? Colors.white
                                : const Color(0xFF604700),
                            size: 11,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ],
  );
}
