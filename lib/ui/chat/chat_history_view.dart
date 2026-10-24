import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import '../shared/app_strings.dart';
import 'message_presentation.dart';

class ChatHistoryRowInsets extends InheritedWidget {
  const ChatHistoryRowInsets({
    super.key,
    required this.horizontal,
    required super.child,
  });
  final double horizontal;
  static double of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ChatHistoryRowInsets>()
          ?.horizontal ??
      0;
  @override
  bool updateShouldNotify(ChatHistoryRowInsets oldWidget) =>
      horizontal != oldWidget.horizontal;
}

class ChatHistoryView extends StatelessWidget {
  const ChatHistoryView({
    super.key,
    required this.entries,
    required this.controller,
    required this.rowKeys,
    required this.wide,
    required this.rowBuilder,
    this.onLoadOlder,
  });
  final List<InboxEntry> entries;
  final ScrollController controller;
  final Map<String, GlobalKey> rowKeys;
  final bool wide;
  final VoidCallback? onLoadOlder;
  final Widget Function(InboxEntry, MessagePresentation) rowBuilder;

  @override
  Widget build(BuildContext context) {
    rowKeys.removeWhere((_, key) => key.currentContext == null);
    final indices = <Key, int>{
      for (var i = 0; i < entries.length; i++)
        ValueKey('chat-row-${entries[i].item.id}'): i,
    };
    return ChatHistoryRowInsets(
      horizontal: wide ? 28 : 14,
      child: ListView.builder(
        key: const ValueKey('self-chat-history'),
        controller: controller,
        reverse: true,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        findChildIndexCallback: (key) => indices[key],
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
        itemCount: entries.length + (onLoadOlder == null ? 0 : 1),
        itemBuilder: (_, index) {
          if (index == entries.length) {
            return Center(
              child: TextButton(
                onPressed: onLoadOlder,
                child: Text(tr(context, '加载更早的消息')),
              ),
            );
          }
          final entry = entries[index];
          return KeyedSubtree(
            key: ValueKey('chat-row-${entry.item.id}'),
            child: KeyedSubtree(
              key: rowKeys.putIfAbsent(entry.item.id, GlobalKey.new),
              child: rowBuilder(entry, MessagePresentation.at(entries, index)),
            ),
          );
        },
      ),
    );
  }
}
