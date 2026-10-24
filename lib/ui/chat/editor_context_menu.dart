import 'package:flutter/material.dart';
import 'desktop_menu.dart';
import 'message_actions.dart';
import 'package:lanflow/ui/shared/app_strings.dart';

/// Uses the same desktop surface as message actions while retaining editor focus.
class EditorContextMenu extends StatelessWidget {
  const EditorContextMenu({
    super.key,
    required this.panelKey,
    required this.anchors,
    required this.items,
  });
  final Key panelKey;
  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> items;

  @override
  Widget build(BuildContext context) {
    final callbacks = <String, VoidCallback>{};
    final actions = <MessageAction>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.onPressed == null) continue;
      final (id, label, icon) = switch (item.type) {
        ContextMenuButtonType.cut => ('cut', '剪切', Icons.content_cut),
        ContextMenuButtonType.copy => (
          'copy',
          '复制',
          Icons.content_copy_outlined,
        ),
        ContextMenuButtonType.paste => (
          'paste',
          '粘贴',
          Icons.content_paste_outlined,
        ),
        ContextMenuButtonType.selectAll => (
          'selectAll',
          '全选',
          Icons.select_all,
        ),
        _ => ('custom-$i', item.label ?? '', Icons.more_horiz),
      };
      final value = 'editor-$id';
      callbacks[value] = item.onPressed!;
      actions.add(MessageAction(value, tr(context, label), icon));
    }
    final overlay = Overlay.of(context, rootOverlay: true);
    final box = overlay.context.findRenderObject()! as RenderBox;
    return DesktopActionMenu(
      panelKey: panelKey,
      position: box.globalToLocal(anchors.primaryAnchor),
      actions: actions,
      takeFocus: false,
      handleKeysWithoutFocus: true,
      onClose: ContextMenuController.removeAny,
      onSelected: (id) {
        ContextMenuController.removeAny();
        callbacks[id]?.call();
      },
    );
  }
}
