import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'message_presentation.dart';

/// Two lazy slivers grow around the original message, so locating a distant
/// result never needs to estimate heights or build the intervening history.
class MessageContext extends StatefulWidget {
  const MessageContext({
    super.key,
    required this.entries,
    required this.targetId,
    required this.wide,
    required this.rowBuilder,
    this.onOlder,
    this.onNewer,
  });
  final List<InboxEntry> entries;
  final String targetId;
  final bool wide;
  final VoidCallback? onOlder, onNewer;
  final Widget Function(InboxEntry entry, MessagePresentation presentation)
  rowBuilder;

  @override
  State<MessageContext> createState() => _MessageContextState();
}

class _MessageContextState extends State<MessageContext> {
  final _center = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    final pivot = entries.indexWhere(
      (entry) => entry.item.id == widget.targetId,
    );
    if (pivot < 0) return Center(child: Text(tr(context, '这条消息已删除，请返回搜索结果')));
    final positions = {
      for (var index = 0; index < entries.length; index++)
        ValueKey(entries[index].item.id): index,
    };
    Widget row(int index) {
      final entry = entries[index];
      final target = entry.item.id == widget.targetId;
      return Padding(
        key: ValueKey(entry.item.id),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: DecoratedBox(
          key: target ? const ValueKey('located-message-highlight') : null,
          decoration: BoxDecoration(
            color: target
                ? Theme.of(context).colorScheme.primary.withValues(alpha: .08)
                : null,
            borderRadius: AppCorners.border,
            border: Border.all(
              color: target
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: widget.rowBuilder(
              entry,
              MessagePresentation.at(entries, index, focused: target),
            ),
          ),
        ),
      );
    }

    return CustomScrollView(
      key: const ValueKey('located-message-history'),
      center: _center,
      anchor: .3,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: widget.wide ? 22 : 8),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, index) => index == entries.length - pivot - 1
                  ? Center(
                      child: TextButton(
                        onPressed: widget.onOlder,
                        child: Text(tr(context, '加载更早的消息')),
                      ),
                    )
                  : row(pivot + 1 + index),
              childCount:
                  entries.length - pivot - 1 + (widget.onOlder == null ? 0 : 1),
              findChildIndexCallback: (key) {
                final index = positions[key];
                return index != null && index > pivot
                    ? index - pivot - 1
                    : null;
              },
            ),
          ),
        ),
        SliverPadding(
          key: _center,
          padding: EdgeInsets.symmetric(horizontal: widget.wide ? 22 : 8),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, index) => index == pivot + 1
                  ? Center(
                      child: TextButton(
                        onPressed: widget.onNewer,
                        child: Text(tr(context, '加载更新的消息')),
                      ),
                    )
                  : row(pivot - index),
              childCount: pivot + 1 + (widget.onNewer == null ? 0 : 1),
              findChildIndexCallback: (key) {
                final index = positions[key];
                return index != null && index <= pivot ? pivot - index : null;
              },
            ),
          ),
        ),
      ],
    );
  }
}
