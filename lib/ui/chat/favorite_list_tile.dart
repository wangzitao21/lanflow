import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/attachment_thumbnail.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/search_text.dart';

import 'favorite_card.dart';
import 'favorite_item_actions.dart';

class FavoriteListTile extends StatelessWidget {
  const FavoriteListTile({
    super.key,
    required this.entry,
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
  final FavoriteEntry entry;
  final Future<File>? imageFile;
  final String query;
  final bool selected, selecting, pinned, enabled;
  final VoidCallback onOpen, onToggle, onDelete;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final item = entry.item;
    final palette = ChatPalette.of(context);
    final icon = switch (item.kind) {
      MessageKind.text => Icons.notes_rounded,
      MessageKind.image => Icons.image_outlined,
      MessageKind.video => Icons.movie_outlined,
      MessageKind.file => Icons.insert_drive_file_outlined,
    };
    Widget preview = Icon(icon, color: palette.muted, size: 26);
    if (imageFile != null) {
      preview = FutureBuilder<File>(
        future: imageFile,
        builder: (context, snapshot) => snapshot.hasData
            ? Center(
                child: AttachmentThumbnail(
                  file: snapshot.data!,
                  maxWidth: 52,
                  maxHeight: 52,
                  semanticLabel: item.name,
                ),
              )
            : Icon(icon, color: palette.muted, size: 26),
      );
    }
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
          key: ValueKey('favorite-${entry.id}'),
          splashFactory: NoSplash.splashFactory,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          onTap: enabled ? (selecting ? onToggle : onOpen) : null,
          onLongPress: enabled ? onToggle : null,
          onSecondaryTapUp: enabled
              ? (details) => onMenu(details.globalPosition)
              : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
            child: Row(
              children: [
                if (selecting) ...[
                  SizedBox(
                    width: 24,
                    child: Checkbox(
                      key: ValueKey('favorite-select-${entry.id}'),
                      value: selected,
                      onChanged: enabled ? (_) => onToggle() : null,
                      visualDensity: VisualDensity.compact,
                      semanticLabel: tr(context, '选择收藏'),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                SizedBox(width: 52, height: 52, child: preview),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (pinned)
                            Padding(
                              padding: const EdgeInsets.only(right: 4, top: 3),
                              child: Tooltip(
                                key: ValueKey('favorite-pin-${entry.id}'),
                                message: tr(context, '已置顶'),
                                child: Icon(
                                  Icons.push_pin_rounded,
                                  size: 14,
                                  color: palette.muted,
                                ),
                              ),
                            ),
                          Expanded(
                            child: HighlightedText(
                              item.isFile ? item.name : item.text,
                              query: query,
                              maxLines: 2,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                      if (item.isFile) ...[
                        const SizedBox(height: 3),
                        Text(
                          formatBytes(item.size),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        '${item.originName} · ${favoriteTimestamp(context, entry.savedAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: palette.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                FavoriteItemActions(
                  id: entry.id,
                  onDelete: onDelete,
                  onMenu: onMenu,
                  enabled: enabled,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
