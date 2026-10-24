import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/chat/message_actions.dart';
import 'package:lanflow/ui/chat/message_text.dart';
import 'package:lanflow/ui/chat/message_bubble.dart';
import 'quote_preview.dart';
import 'package:lanflow/ui/chat/message_selection.dart';
import 'package:lanflow/ui/chat/chat_history_view.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/profile_avatar.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/shared/search_text.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/attachment_thumbnail.dart';

typedef MessageMenuCallback =
    Future<void> Function(InboxItem item, Offset position, {Rect? anchor});

class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.inbox,
    required this.entry,
    required this.showTime,
    required this.wide,
    required this.onOpen,
    required this.onLink,
    required this.onMenu,
    required this.onStatus,
    required this.onSelectionChanged,
    this.highlightQuery = '',
    this.showIdentity = true,
    this.showStatus = true,
    this.onQuote,
  });

  final InboxController inbox;
  final InboxEntry entry;
  final bool showTime;
  final bool wide;
  final String highlightQuery;
  final bool showIdentity, showStatus;
  final Future<void> Function(InboxItem) onOpen;
  final Future<void> Function(String) onLink;
  final MessageMenuCallback onMenu;
  final VoidCallback onStatus;
  final ValueChanged<MessageQuote>? onQuote;
  final ValueChanged<String?> onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final palette = ChatPalette.of(context);
    final muted = palette.muted;
    final lan = inbox.lan;
    final item = entry.item;
    final local = lan.identityReady && item.originId == lan.identity.id;
    final time = item.createdAt.toLocal();
    final now = DateTime.now();
    final day =
        time.year == now.year && time.month == now.month && time.day == now.day
        ? ''
        : '${MaterialLocalizations.of(context).formatMediumDate(time)} ';
    final stamp =
        '$day${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final peer = lan.peers[item.originId];
    final horizontalInset = ChatHistoryRowInsets.of(context);
    Widget content;
    if (!item.isFile) {
      content = MessageBubble(
        outgoing: local,
        textCursor: AppLayout.desktop(context),
        tailOffset: !local && showIdentity ? 12 : 20,
        child: MessageText(
          text: item.text,
          highlightQuery: highlightQuery,
          onLink: onLink,
          outgoing: local,
          fontSize: ChatMetrics.messageFontSize,
          selectable: AppLayout.desktop(context),
          onSelectionChanged: onSelectionChanged,
        ),
      );
    } else if (item.kind == MessageKind.image) {
      content = InkWell(
        onTap: () => onOpen(item),
        customBorder: MessageBubbleBorder(
          outgoing: local,
          tailOffset: !local && showIdentity ? 12 : 20,
        ),
        child: MessageBubble(
          key: ValueKey('media-bubble-${item.id}'),
          outgoing: local,
          backgroundColor: palette.surface,
          contentPadding: EdgeInsets.zero,
          minHeight: 0,
          tailOffset: !local && showIdentity ? 12 : 20,
          child: AttachmentThumbnail(
            key: ValueKey('image-thumbnail-${item.id}'),
            file: inbox.store.blob(item.digest),
            maxWidth: wide
                ? ChatMetrics.imageWidthDesktop
                : ChatMetrics.imageWidthMobile,
            maxHeight: wide
                ? ChatMetrics.imageHeightDesktop
                : ChatMetrics.imageHeightMobile,
            semanticLabel: item.name,
          ),
        ),
      );
    } else {
      content = InkWell(
        onTap: () => onOpen(item),
        borderRadius: AppCorners.border,
        child: MessageBubble(
          key: ValueKey('media-bubble-${item.id}'),
          outgoing: local,
          backgroundColor: palette.surface,
          contentPadding: const EdgeInsets.all(12),
          tailOffset: !local && showIdentity ? 12 : 20,
          child: SizedBox(
            width: 246,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      HighlightedText(
                        item.name,
                        query: highlightQuery,
                        maxLines: 3,
                        style: TextStyle(
                          fontSize: AppTypography.secondary,
                          height: 1.5,
                        ),
                      ),
                      SizedBox(height: 9),
                      Text(
                        formatBytes(item.size),
                        style: TextStyle(
                          color: muted,
                          fontSize: AppTypography.caption,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 16),
                Container(
                  width: 42,
                  height: 48,
                  decoration: BoxDecoration(
                    color: item.kind == MessageKind.video
                        ? palette.videoBadge
                        : palette.fileBadge,
                    borderRadius: AppCorners.border,
                  ),
                  child: Icon(
                    item.kind == MessageKind.video
                        ? Icons.play_arrow_rounded
                        : Icons.description_outlined,
                    color: Colors.white,
                    size: 29,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (item.quote case final quote?) {
      final source = inbox.store.find(quote.id)?.item;
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: local
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          content,
          QuotePreview(
            quote: quote,
            onTap: () => onQuote?.call(quote),
            source: source,
            image: source?.kind == MessageKind.image
                ? inbox.store.blob(source!.digest)
                : null,
          ),
        ],
      );
    }
    if (item.kind == MessageKind.image && highlightQuery.isNotEmpty) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          content,
          const SizedBox(height: 4),
          HighlightedText(
            item.name,
            query: highlightQuery,
            maxLines: 2,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      );
    }
    return Column(
      key: ValueKey('chat-row-${item.id}'),
      children: [
        if (showTime)
          Padding(
            padding: EdgeInsets.only(top: 12, bottom: 20),
            child: Text(
              stamp,
              style: TextStyle(fontSize: AppTypography.caption, color: muted),
            ),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            final maxBubble =
                (constraints.maxWidth - horizontalInset * 2 - 56) *
                (wide ? 0.78 : 0.91);
            final body = Flexible(
              child: Column(
                crossAxisAlignment: local
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  if (!local && showIdentity)
                    Padding(
                      padding: EdgeInsets.only(bottom: 6),
                      child: Text(
                        inbox.deviceName(item.originId, item.originName),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTypography.caption,
                          color: muted,
                        ),
                      ),
                    ),
                  Listener(
                    key: ValueKey('inbox-item-${item.id}'),
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (event) {
                      if (event.buttons == kSecondaryMouseButton) {
                        unawaited(onMenu(item, event.position));
                      }
                    },
                    child: MessageHold(
                      onHold: (position, anchor) =>
                          onMenu(item, position, anchor: anchor),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: maxBubble),
                        child: content,
                      ),
                    ),
                  ),
                  if (local)
                    Padding(
                      padding: EdgeInsets.zero,
                      child: ValueListenableBuilder<int>(
                        valueListenable: inbox.activity,
                        builder: (context, _, _) {
                          final details = inbox.copyDetails(entry);
                          if (!showStatus &&
                              details.every(
                                (detail) => detail.state == CopyState.complete,
                              )) {
                            return const SizedBox.shrink();
                          }
                          final failed = details.any(
                            (detail) => detail.state == CopyState.failed,
                          );
                          return TextButton.icon(
                            key: ValueKey('copy-status-${item.id}'),
                            onPressed: onStatus,
                            style: TextButton.styleFrom(
                              foregroundColor: failed
                                  ? Theme.of(context).colorScheme.error
                                  : muted,
                              minimumSize: Size(
                                0,
                                AppLayout.desktop(context) ? 24 : 48,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 0,
                              ),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            icon: Icon(
                              failed
                                  ? Icons.error_outline_rounded
                                  : Icons.info_outline_rounded,
                              size: 12,
                            ),
                            label: Text(
                              tr(context, inbox.copyStatus(entry)),
                              style: const TextStyle(
                                fontSize: AppTypography.caption,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            );
            final avatar = SizedBox(
              key: ValueKey('message-avatar-slot-${item.id}'),
              width: 40,
              height: 40,
              child: showIdentity
                  ? ProfileAvatar(
                      inbox: inbox,
                      local: local,
                      deviceId: local ? null : item.originId,
                      platform: local ? null : peer?.platform ?? 'android',
                    )
                  : null,
            );
            return MessageSelectionRow(
              padding: EdgeInsets.fromLTRB(
                horizontalInset,
                0,
                horizontalInset,
                ChatMetrics.rowGap,
              ),
              child: Row(
                mainAxisAlignment: local
                    ? MainAxisAlignment.end
                    : MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: local
                    ? [body, SizedBox(width: 8), avatar]
                    : [avatar, SizedBox(width: 8), body],
              ),
            );
          },
        ),
      ],
    );
  }
}
