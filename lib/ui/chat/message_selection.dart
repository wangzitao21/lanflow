import 'package:flutter/material.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/app_strings.dart';

class MessageSelection extends ChangeNotifier {
  String? conversation;
  final Set<String> ids = {};
  bool busy = false;
  bool get active => conversation != null;

  void begin(String conversationId, [String? id]) {
    conversation = conversationId;
    ids.clear();
    if (id != null) ids.add(id);
    notifyListeners();
  }

  void toggle(String id) {
    if (busy) return;
    if (!ids.remove(id)) ids.add(id);
    notifyListeners();
  }

  void selectAll(Iterable<String> values) {
    if (busy) return;
    ids
      ..clear()
      ..addAll(values);
    notifyListeners();
  }

  void retain(Set<String> existing) {
    if (busy) return;
    final before = ids.length;
    ids.retainAll(existing);
    if (before != ids.length) notifyListeners();
  }

  void setBusy(bool value) {
    busy = value;
    notifyListeners();
  }

  void clear() {
    if (busy || !active) return;
    conversation = null;
    ids.clear();
    notifyListeners();
  }
}

class SelectableMessage extends StatelessWidget {
  const SelectableMessage({
    super.key,
    required this.selection,
    required this.id,
    required this.child,
  });
  final MessageSelection selection;
  final String id;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      _MessageSelectionScope(selection: selection, id: id, child: child);
}

class _MessageSelectionScope extends InheritedNotifier<MessageSelection> {
  const _MessageSelectionScope({
    required MessageSelection selection,
    required this.id,
    required super.child,
  }) : super(notifier: selection);

  final String id;

  @override
  bool updateShouldNotify(_MessageSelectionScope oldWidget) =>
      id != oldWidget.id || super.updateShouldNotify(oldWidget);
}

/// Selection belongs to the avatar row, not its timestamp or bubble's height.
/// Only selection mode inserts a control and a separate gap before the avatar.
class MessageSelectionRow extends StatelessWidget {
  const MessageSelectionRow({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_MessageSelectionScope>();
    if (scope == null) return Padding(padding: padding, child: child);
    final palette = ChatPalette.of(context);
    final selection = scope.notifier!;
    final active = selection.active;
    final selected = selection.ids.contains(scope.id);
    final toggle = active && !selection.busy
        ? () => selection.toggle(scope.id)
        : null;
    return Semantics(
      checked: active ? selected : null,
      enabled: active ? !selection.busy : null,
      label: active ? tr(context, selected ? '已选择消息' : '选择消息') : null,
      onTap: toggle,
      child: Material(
        color: active && selected
            ? Color.alphaBlend(
                (Theme.of(context).brightness == Brightness.dark
                        ? Colors.white
                        : Colors.black)
                    .withValues(alpha: .06),
                palette.canvas,
              )
            : Colors.transparent,
        child: InkWell(
          key: ValueKey('select-message-${scope.id}'),
          excludeFromSemantics: true,
          onTap: toggle,
          child: Padding(
            padding: padding,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (active) ...[
                  SizedBox(
                    width: 24,
                    height: 40,
                    child: ExcludeSemantics(
                      child: IgnorePointer(
                        child: Checkbox(
                          key: ValueKey('message-checkbox-${scope.id}'),
                          value: selected,
                          onChanged: selection.busy ? null : (_) {},
                          shape: const CircleBorder(),
                          activeColor: brandGreen,
                          checkColor: Colors.white,
                          side: WidgetStateBorderSide.resolveWith(
                            (states) => BorderSide(
                              color: states.contains(WidgetState.selected)
                                  ? brandGreen
                                  : palette.muted,
                              width: 1.5,
                            ),
                          ),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                ],
                Expanded(
                  child: ExcludeFocus(
                    excluding: active,
                    child: IgnorePointer(ignoring: active, child: child),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MessageSelectionBar extends StatelessWidget {
  const MessageSelectionBar({
    super.key,
    required this.selection,
    required this.onAll,
    required this.onDelete,
    required this.onExport,
    required this.onFavorite,
    this.compact = false,
    this.panel = false,
  });
  final MessageSelection selection;
  final VoidCallback onAll, onDelete, onExport, onFavorite;
  final bool compact;
  final bool panel;

  @override
  Widget build(BuildContext context) {
    if (panel) return _panel(context);
    final actions = <Widget>[
      Text(
        tr(context, '已选 {count} 条', {'count': selection.ids.length}),
        key: const ValueKey('message-selection-count'),
      ),
      TextButton(
        onPressed: selection.busy ? null : onAll,
        child: Text(tr(context, '全选')),
      ),
      TextButton(
        onPressed: selection.busy ? null : selection.clear,
        child: Text(tr(context, '取消多选')),
      ),
      TextButton.icon(
        onPressed: selection.busy || selection.ids.isEmpty ? null : onFavorite,
        icon: const Icon(Icons.star_border, size: 18),
        label: Text(tr(context, '收藏')),
      ),
      TextButton.icon(
        onPressed: selection.busy || selection.ids.isEmpty ? null : onExport,
        icon: const Icon(Icons.save_alt, size: 18),
        label: Text(tr(context, '导出')),
      ),
      FilledButton.icon(
        key: const ValueKey('delete-selected-messages'),
        onPressed: selection.busy || selection.ids.isEmpty ? null : onDelete,
        style: FilledButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.error,
          foregroundColor: Theme.of(context).colorScheme.onError,
        ),
        icon: const Icon(Icons.delete_outline, size: 18),
        label: Text(tr(context, selection.busy ? '处理中…' : '删除所选')),
      ),
    ];
    return Material(
      color: ChatPalette.of(context).surface,
      child: Padding(
        padding: compact
            ? const EdgeInsets.symmetric(horizontal: 4)
            : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: compact
            ? SizedBox(
                height: 48,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < actions.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        actions[i],
                      ],
                    ],
                  ),
                ),
              )
            : Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: actions,
              ),
      ),
    );
  }

  Widget _panel(BuildContext context) {
    final palette = ChatPalette.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.5);
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : 144.0;
        final short = height <= 80;
        final showCount = height >= 120;
        final tileHeight = short ? height.clamp(0.0, 48.0) : 76.0;
        final tileWidth = 80.0 * scale;
        Widget action(
          String id,
          String label,
          IconData icon,
          VoidCallback? callback, {
          bool destructive = false,
        }) => SizedBox(
          width: tileWidth,
          height: tileHeight,
          child: TextButton(
            key: id == 'delete'
                ? const ValueKey('delete-selected-messages')
                : ValueKey('selection-panel-$id'),
            onPressed: callback,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              foregroundColor: destructive
                  ? Theme.of(context).colorScheme.error
                  : palette.text,
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: short ? 20 : 26),
                  SizedBox(height: short ? 3 : 8),
                  Text(
                    tr(context, label),
                    style: const TextStyle(fontSize: AppTypography.compact),
                  ),
                ],
              ),
            ),
          ),
        );
        final enabled = !selection.busy && selection.ids.isNotEmpty;
        return SizedBox(
          height: height,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (showCount) ...[
                Text(
                  tr(context, '已选 {count} 条', {'count': selection.ids.length}),
                  key: const ValueKey('message-selection-count'),
                  style: TextStyle(
                    fontSize: AppTypography.caption,
                    color: palette.muted,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  if (!short) const SizedBox(width: 52),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, available) => SingleChildScrollView(
                        key: const ValueKey('selection-panel-scroll'),
                        scrollDirection: Axis.horizontal,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minWidth: available.maxWidth,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              action(
                                'all',
                                '全选',
                                Icons.done_all,
                                selection.busy ? null : onAll,
                              ),
                              action(
                                'favorite',
                                '收藏',
                                Icons.star_border,
                                enabled ? onFavorite : null,
                              ),
                              action(
                                'export',
                                '导出',
                                Icons.save_alt,
                                enabled ? onExport : null,
                              ),
                              action(
                                'delete',
                                selection.busy ? '处理中…' : '删除',
                                Icons.delete_outline,
                                enabled ? onDelete : null,
                                destructive: true,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    height: tileHeight,
                    child: IconButton(
                      key: const ValueKey('cancel-message-selection'),
                      tooltip: tr(context, '取消多选'),
                      onPressed: selection.busy ? null : selection.clear,
                      icon: const Icon(Icons.close, size: 24),
                      color: palette.muted,
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
