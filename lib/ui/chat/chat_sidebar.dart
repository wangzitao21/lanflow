import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/profile_avatar.dart';
import 'package:lanflow/ui/shared/app_strings.dart';

class ChatSidebar extends StatelessWidget {
  const ChatSidebar({
    super.key,
    required this.inbox,
    required this.search,
    required this.onSettings,
    required this.onProfile,
    required this.onDevices,
    required this.onTransfers,
    required this.onFavorites,
    required this.onTrash,
    this.compact = false,
    this.keyboardVisible = false,
    this.showNavigation = true,
  });
  final InboxController inbox;
  final Widget search;
  final VoidCallback onSettings,
      onProfile,
      onDevices,
      onTransfers,
      onFavorites,
      onTrash;
  final bool compact;
  final bool keyboardVisible;
  final bool showNavigation;

  @override
  Widget build(BuildContext context) {
    final palette = ChatPalette.of(context);
    final list = Material(
      color: palette.sidebar,
      child: Column(
        children: [
          Expanded(child: search),
          if (!keyboardVisible)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                tr(
                  context,
                  inbox.syncTargets.isEmpty
                      ? '连接设备后同步消息'
                      : '已绑定 ${inbox.syncTargets.length} 台设备',
                ),
                style: TextStyle(
                  color: palette.muted,
                  fontSize: AppTypography.caption,
                ),
              ),
            ),
        ],
      ),
    );
    if (!showNavigation) {
      return compact
          ? list
          : SizedBox(
              width: AppLayout.desktop(context) ? 250 : 270,
              child: list,
            );
    }
    if (compact && !AppLayout.desktop(context)) return list;
    return Row(
      children: [
        Container(
          key: const ValueKey('desktop-navigation-rail'),
          width: 60,
          color: palette.rail,
          padding: const EdgeInsets.symmetric(vertical: 22),
          child: Column(
            children: [
              Tooltip(
                message: tr(context, '修改头像与名称'),
                child: InkWell(
                  onTap: onProfile,
                  borderRadius: AppCorners.border,
                  child: ProfileAvatar(inbox: inbox, local: true, size: 36),
                ),
              ),
              const SizedBox(height: 28),
              const Icon(
                Icons.chat_bubble_outline,
                color: brandGreen,
                size: 24,
              ),
              const SizedBox(height: 20),
              IconButton(
                tooltip: tr(context, '收藏'),
                onPressed: onFavorites,
                icon: const Icon(Icons.star_border_rounded),
              ),
              const Spacer(),
              IconButton(
                tooltip: tr(context, '回收站'),
                onPressed: onTrash,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
              IconButton(
                tooltip: tr(context, '设置'),
                onPressed: onSettings,
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
        ),
        if (compact)
          Expanded(child: list)
        else
          SizedBox(width: 270, child: list),
      ],
    );
  }
}
