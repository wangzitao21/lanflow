import 'package:flutter/material.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';

class FavoriteItemActions extends StatelessWidget {
  const FavoriteItemActions({
    super.key,
    required this.id,
    required this.onDelete,
    required this.onMenu,
    this.enabled = true,
  });
  final String id;
  final VoidCallback onDelete;
  final ValueChanged<Offset> onMenu;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(32, 36)),
      maximumSize: const WidgetStatePropertyAll(Size(32, 36)),
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      splashFactory: NoSplash.splashFactory,
      overlayColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)
            ? ChatPalette.of(context).divider.withValues(alpha: .4)
            : Colors.transparent,
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: ValueKey('favorite-delete-$id'),
          tooltip: tr(context, '删除收藏'),
          style: style,
          onPressed: enabled ? onDelete : null,
          icon: const Icon(Icons.delete_outline_rounded, size: 17),
        ),
        Builder(
          builder: (buttonContext) => IconButton(
            key: ValueKey('favorite-menu-$id'),
            tooltip: tr(context, '更多操作'),
            style: style,
            onPressed: enabled
                ? () {
                    final box = buttonContext.findRenderObject()! as RenderBox;
                    onMenu(box.localToGlobal(Offset(0, box.size.height)));
                  }
                : null,
            icon: const Icon(Icons.more_horiz_rounded, size: 19),
          ),
        ),
      ],
    );
  }
}
