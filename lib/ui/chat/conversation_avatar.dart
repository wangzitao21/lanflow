import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';

const conversationIcons = <String, (String, IconData)>{
  'chat': ('会话', Icons.chat_bubble_outline_rounded),
  'folder': ('文件', Icons.folder_open_rounded),
  'work': ('工作', Icons.work_outline_rounded),
  'idea': ('灵感', Icons.lightbulb_outline_rounded),
  'book': ('阅读', Icons.menu_book_rounded),
  'star': ('星标', Icons.star_border_rounded),
  'home': ('生活', Icons.home_outlined),
  'heart': ('喜欢', Icons.favorite_border_rounded),
};

class ConversationAvatar extends StatelessWidget {
  const ConversationAvatar({
    super.key,
    required this.id,
    this.avatar,
    this.color,
    this.size = 42,
  });
  final String id;
  final String? avatar;
  final int? color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color != null
          ? Color(color!)
          : id == defaultConversationId
          ? brandGreen
          : const Color(0xFF5B88AE),
      borderRadius: AppCorners.border,
    ),
    child: Icon(
      conversationIcons[avatar]?.$2 ??
          (id == defaultConversationId
              ? Icons.folder_copy_outlined
              : Icons.chat_bubble_outline),
      color: Colors.white,
      size: size * .57,
    ),
  );
}
