import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/chat/message_actions.dart';
import 'conversation_avatar.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/app_strings.dart';

class ConversationList extends StatefulWidget {
  const ConversationList({
    super.key,
    required this.inbox,
    required this.mobile,
    required this.onOpen,
    required this.onMenu,
  });
  final InboxController inbox;
  final bool mobile;
  final ValueChanged<String> onOpen;
  final Future<void> Function(String? id, Offset position, {Rect? anchor})
  onMenu;

  @override
  State<ConversationList> createState() => _ConversationListState();
}

class _ConversationListState extends State<ConversationList> {
  String? _draggedId;
  InboxController get inbox => widget.inbox;
  bool get mobile => widget.mobile;
  ValueChanged<String> get onOpen => widget.onOpen;
  Future<void> Function(String? id, Offset position, {Rect? anchor})
  get onMenu => widget.onMenu;

  Widget _buildList(
    List<Conversation> conversations, {
    required IndexedWidgetBuilder itemBuilder,
  }) {
    if (mobile) {
      return ListView.builder(
        key: const PageStorageKey('conversation-list-scroll'),
        padding: EdgeInsets.zero,
        itemCount: conversations.length,
        itemBuilder: itemBuilder,
      );
    }
    return ReorderableListView.builder(
      key: const PageStorageKey('conversation-list-scroll'),
      padding: EdgeInsets.zero,
      itemCount: conversations.length,
      buildDefaultDragHandles: false,
      onReorderStart: (index) => _draggedId = conversations[index].id,
      onReorderItem: (oldIndex, newIndex) {
        final id = _draggedId ?? conversations[oldIndex].id;
        _draggedId = null;
        unawaited(
          inbox
              .reorderConversation(id, newIndex)
              .catchError(
                (Object error) => inbox.reportError('会话顺序保存失败：$error'),
              ),
        );
      },
      itemBuilder: (context, index) => ReorderableDragStartListener(
        key: ValueKey('conversation-row-${conversations[index].id}'),
        index: index,
        child: itemBuilder(context, index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: inbox.draftActivity,
    builder: (context, _, _) => _list(context),
  );

  Widget _list(BuildContext context) {
    final palette = ChatPalette.of(context);
    final conversations = inbox.conversations;
    return GestureDetector(
      key: const ValueKey('conversation-list'),
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (details) =>
          unawaited(onMenu(null, details.globalPosition)),
      child: conversations.isEmpty
          ? Center(
              child: Text(
                tr(context, '点击加号新建会话'),
                style: TextStyle(color: palette.muted),
              ),
            )
          : _buildList(
              conversations,
              itemBuilder: (context, index) {
                final conversation = conversations[index];
                final preference = inbox.store.preference(conversation.id);
                final latest = inbox.store.latestIn(conversation.id)?.item;
                final draft = inbox.store.drafts[conversation.id]?.trim() ?? '';
                final attachments =
                    inbox.store.attachmentDrafts[conversation.id] ?? [];
                final hasDraft =
                    draft.isNotEmpty ||
                    attachments.isNotEmpty ||
                    inbox.store.draftQuotes.containsKey(conversation.id);
                final draftPreview = draft.isNotEmpty
                    ? draft.replaceAll('\n', ' ')
                    : attachments.isNotEmpty
                    ? tr(context, '待发送 · {count} 个附件', {
                        'count': attachments.length,
                      })
                    : tr(context, '引用');
                final preview = latest == null
                    ? tr(context, '文字、图片、文件，随时发给自己')
                    : latest.isFile
                    ? '[${tr(context, switch (latest.kind) {
                        MessageKind.image => '图片',
                        MessageKind.video => '视频',
                        _ => '文件',
                      })}] ${latest.name}'
                    : latest.text.replaceAll('\n', ' ');
                final time = latest?.createdAt.toLocal();
                final now = DateTime.now();
                final stamp = time == null
                    ? ''
                    : time.year == now.year &&
                          time.month == now.month &&
                          time.day == now.day
                    ? '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}'
                    : '${time.month}/${time.day}';
                final selected =
                    !mobile && inbox.conversationId == conversation.id;
                final unread = inbox.unreadCount(conversation.id);
                final unreadLabel = unread > 99
                    ? '99+'
                    : '${unread > 0 ? unread : 1}';
                return GestureDetector(
                  onSecondaryTapUp: (details) => unawaited(
                    onMenu(conversation.id, details.globalPosition),
                  ),
                  child: MessageHold(
                    onHold: (position, anchor) => unawaited(
                      onMenu(conversation.id, position, anchor: anchor),
                    ),
                    child: Semantics(
                      selected: selected,
                      child: Material(
                        color: selected ? palette.selected : palette.surface,
                        child: Stack(
                          children: [
                            InkWell(
                              key: ValueKey('conversation-${conversation.id}'),
                              onTap: () => onOpen(conversation.id),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 13,
                                ),
                                child: Row(
                                  children: [
                                    Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        ConversationAvatar(
                                          id: conversation.id,
                                          avatar: conversation.avatar,
                                          color: conversation.avatarColor,
                                        ),
                                        if (preference.manualUnread ||
                                            unread > 0)
                                          Positioned(
                                            top: -6,
                                            right: -8,
                                            child: Semantics(
                                              label: tr(
                                                context,
                                                unread == 0
                                                    ? '已标为未读'
                                                    : '$unread 条未读消息',
                                              ),
                                              excludeSemantics: true,
                                              child: Container(
                                                key: ValueKey(
                                                  'unread-${conversation.id}',
                                                ),
                                                constraints:
                                                    const BoxConstraints(
                                                      minWidth: 20,
                                                      minHeight: 20,
                                                    ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 4,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: palette.unreadBadge,
                                                  borderRadius:
                                                      BorderRadius.circular(20),
                                                  border: Border.all(
                                                    color: palette.sidebar,
                                                    width: 1.5,
                                                  ),
                                                ),
                                                child: Text(
                                                  unreadLabel,
                                                  textAlign: TextAlign.center,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize:
                                                        AppTypography.metadata,
                                                    height: 1,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  conversation.id ==
                                                              defaultConversationId &&
                                                          conversation.name ==
                                                              '发给自己'
                                                      ? tr(context, '发给自己')
                                                      : conversation.name,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize:
                                                        AppTypography.secondary,
                                                    color: palette.text,
                                                    fontWeight: selected
                                                        ? FontWeight.w600
                                                        : FontWeight.w400,
                                                  ),
                                                ),
                                              ),
                                              if (preference.pinnedAt != null)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        right: 4,
                                                      ),
                                                  child: Icon(
                                                    Icons.push_pin,
                                                    size: 12,
                                                    color: palette.muted,
                                                  ),
                                                ),
                                              Text(
                                                stamp,
                                                style: TextStyle(
                                                  fontSize:
                                                      AppTypography.metadata,
                                                  color: palette.muted,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 5),
                                          Text.rich(
                                            TextSpan(
                                              children: [
                                                if (hasDraft)
                                                  TextSpan(
                                                    text:
                                                        '[${tr(context, '草稿')}] ',
                                                    style: TextStyle(
                                                      color:
                                                          palette.unreadBadge,
                                                    ),
                                                  ),
                                                TextSpan(
                                                  text: hasDraft
                                                      ? draftPreview
                                                      : preview,
                                                ),
                                              ],
                                            ),
                                            key: ValueKey(
                                              'conversation-preview-${conversation.id}',
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: AppTypography.caption,
                                              color: palette.muted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (selected)
                              Positioned(
                                left: 0,
                                top: 12,
                                bottom: 12,
                                width: 4,
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    key: ValueKey(
                                      'selected-conversation-${conversation.id}',
                                    ),
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                      borderRadius:
                                          const BorderRadius.horizontal(
                                            right: Radius.circular(3),
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
