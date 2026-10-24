import 'package:flutter/material.dart';

import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/app_strings.dart';

class ChatHeader extends StatelessWidget {
  const ChatHeader({
    super.key,
    required this.inbox,
    required this.wide,
    required this.onBack,
    required this.onSearch,
    required this.onTransfers,
    required this.onDevices,
    required this.onSettings,
    this.onSelect,
    this.title,
  });

  final InboxController inbox;
  final bool wide;
  final VoidCallback onBack;
  final VoidCallback onSearch;
  final VoidCallback onTransfers;
  final VoidCallback onDevices;
  final VoidCallback onSettings;
  final VoidCallback? onSelect;
  final Widget? title;

  @override
  Widget build(BuildContext context) {
    final palette = ChatPalette.of(context);
    final ink = palette.text;
    final muted = palette.muted;
    return ValueListenableBuilder<int>(
      valueListenable: inbox.activity,
      builder: (context, _, _) {
        final status = inbox.connectionSummary;
        final stackActions =
            !wide &&
            (MediaQuery.sizeOf(context).width <= 360 ||
                MediaQuery.textScalerOf(context).scale(14) > 18);
        final actions = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onSelect != null)
              IconButton(
                tooltip: tr(context, '多选消息'),
                onPressed: onSelect,
                icon: const Icon(Icons.checklist_rounded, size: 22),
              ),
            if (!wide)
              IconButton(
                tooltip: tr(context, '设置'),
                onPressed: onSettings,
                icon: const Icon(Icons.settings_outlined, size: 20),
              ),
          ],
        );
        return Container(
          constraints: const BoxConstraints(minHeight: 68),
          decoration: BoxDecoration(
            color: palette.canvas,
            border: Border(
              bottom: BorderSide(color: palette.divider, width: .6),
            ),
          ),
          padding: EdgeInsets.fromLTRB(wide ? 24 : 4, 8, 10, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (!wide)
                    IconButton(
                      tooltip: tr(context, '返回会话'),
                      onPressed: onBack,
                      icon: Icon(Icons.chevron_left, size: 30),
                    ),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        title ??
                            Text(
                              inbox.conversationId == defaultConversationId &&
                                      inbox.conversation.name == '发给自己'
                                  ? tr(context, '发给自己')
                                  : inbox.conversation.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: AppTypography.conversationTitle,
                                fontWeight: FontWeight.w500,
                                color: ink,
                              ),
                            ),
                        SizedBox(height: 3),
                        Tooltip(
                          message: tr(context, '我的设备'),
                          child: InkWell(
                            onTap: onDevices,
                            child: Text(
                              tr(context, status),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: AppTypography.caption,
                                color: muted,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!stackActions) actions,
                ],
              ),
              if (stackActions)
                Align(alignment: Alignment.centerRight, child: actions),
            ],
          ),
        );
      },
    );
  }
}
