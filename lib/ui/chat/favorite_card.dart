import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/attachment_thumbnail.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/search_text.dart';

import 'favorite_item_actions.dart';

String favoriteTimestamp(BuildContext context, DateTime value) {
  final local = value.toLocal();
  final material = MaterialLocalizations.of(context);
  return '${material.formatShortDate(local)} ${material.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: true)}';
}

class FavoriteCard extends StatelessWidget {
  const FavoriteCard({
    super.key,
    required this.id,
    required this.item,
    required this.savedAt,
    required this.source,
    required this.onOpen,
    required this.onToggle,
    required this.onMenu,
    required this.onDelete,
    this.imageFile,
    this.query = '',
    this.selected = false,
    this.selecting = false,
    this.pinned = false,
    this.enabled = true,
  });

  final String id;
  final InboxItem item;
  final DateTime savedAt;
  final String source;
  final String query;
  final Future<File>? imageFile;
  final bool selected, selecting, pinned, enabled;
  final VoidCallback onOpen, onToggle, onDelete;
  final ValueChanged<Offset> onMenu;

  Widget _preview(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) => Align(
      alignment: Alignment.center,
      child: FutureBuilder<File>(
        future: imageFile,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            return AttachmentThumbnail(
              file: snapshot.data!,
              maxWidth: bounds.maxWidth,
              maxHeight: math.min(300, bounds.maxWidth * 1.6),
              semanticLabel: item.name,
            );
          }
          return SizedBox(
            width: 136,
            height: 88,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.image_not_supported_outlined,
                  color: ChatPalette.of(context).muted,
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: Text(
                    tr(context, snapshot.hasError ? '附件暂不可用' : '加载中…'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final palette = ChatPalette.of(context);
    final kind = switch (item.kind) {
      MessageKind.text => '文字',
      MessageKind.image => '图片',
      MessageKind.video => '视频',
      MessageKind.file => '文件',
    };
    final icon = switch (item.kind) {
      MessageKind.text => Icons.notes_rounded,
      MessageKind.image => Icons.image_outlined,
      MessageKind.video => Icons.movie_outlined,
      MessageKind.file => Icons.insert_drive_file_outlined,
    };
    return Semantics(
      selected: selecting ? selected : null,
      child: Material(
        color: selected ? palette.selected : palette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: AppCorners.border,
          side: BorderSide(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : palette.divider,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('favorite-$id'),
          splashFactory: NoSplash.splashFactory,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          onTap: enabled ? (selecting ? onToggle : onOpen) : null,
          onLongPress: enabled ? onToggle : null,
          onSecondaryTapUp: enabled
              ? (details) => onMenu(details.globalPosition)
              : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (item.kind == MessageKind.image && imageFile != null) ...[
                  const SizedBox(height: 8),
                  _preview(context),
                  const SizedBox(height: 4),
                ],
                Row(
                  children: [
                    SizedBox(
                      width: 24,
                      height: 40,
                      child: selecting
                          ? Checkbox(
                              key: ValueKey('favorite-select-$id'),
                              value: selected,
                              onChanged: enabled ? (_) => onToggle() : null,
                              semanticLabel: tr(context, '选择收藏'),
                              visualDensity: VisualDensity.compact,
                            )
                          : Icon(icon, size: 16, color: palette.muted),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        tr(context, kind),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (pinned)
                      Tooltip(
                        key: ValueKey('favorite-pin-$id'),
                        message: tr(context, '已置顶'),
                        child: Icon(
                          Icons.push_pin_rounded,
                          size: 13,
                          color: palette.muted,
                        ),
                      ),
                    FavoriteItemActions(
                      id: id,
                      onDelete: onDelete,
                      onMenu: onMenu,
                      enabled: enabled,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (!item.isFile)
                  HighlightedText(
                    item.text,
                    query: query,
                    maxLines: 5,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(height: 1.5),
                  ),
                if (item.kind == MessageKind.image && imageFile != null) ...[
                  HighlightedText(
                    item.name,
                    query: query,
                    maxLines: 2,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatBytes(item.size),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (item.isFile &&
                    (item.kind != MessageKind.image || imageFile == null))
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 36,
                        height: 44,
                        decoration: BoxDecoration(
                          color:
                              (item.kind == MessageKind.video
                                      ? palette.videoBadge
                                      : palette.fileBadge)
                                  .withValues(alpha: .18),
                          borderRadius: AppCorners.border,
                        ),
                        child: Icon(
                          icon,
                          size: 24,
                          color: item.kind == MessageKind.video
                              ? palette.videoBadge
                              : palette.fileBadge,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            HighlightedText(
                              item.name,
                              query: query,
                              maxLines: 3,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w500),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              formatBytes(item.size),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 10),
                Text(
                  '$source · ${tr(context, '收藏于 {date}', {'date': favoriteTimestamp(context, savedAt)})}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: palette.muted,
                    fontSize: AppTypography.caption,
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
