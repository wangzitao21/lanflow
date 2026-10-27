import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/platform/platform_bridge.dart';
import 'package:lanflow/ui/shared/app_feedback.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/attachment_thumbnail.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';

import 'favorite_actions.dart';
import 'favorite_card.dart';
import 'image_viewer.dart';
import 'message_actions.dart';
import 'message_text.dart';

class FavoriteDetail extends StatefulWidget {
  const FavoriteDetail({
    super.key,
    required this.inbox,
    required this.entry,
    required this.onDelete,
    required this.onBack,
    this.onLocate,
    this.embedded = false,
  });
  final InboxController inbox;
  final FavoriteEntry entry;
  final Future<bool> Function() onDelete;
  final VoidCallback onBack;
  final ValueChanged<InboxEntry>? onLocate;
  final bool embedded;

  @override
  State<FavoriteDetail> createState() => FavoriteDetailState();
}

class FavoriteDetailState extends State<FavoriteDetail> {
  FavoriteEntry get _entry =>
      widget.inbox.favoriteEntries
          .where((entry) => entry.id == widget.entry.id)
          .firstOrNull ??
      widget.entry;
  late final _actions = FavoriteActions(widget.inbox);
  Future<File>? _image;
  Object? _imageKey;
  int? _imageRevision;
  bool _imageFailed = false;
  bool _busy = false;
  bool _deleting = false;
  String? _error;

  void requestBack() {
    if (!_busy) widget.onBack();
  }

  Future<File> _imageFile() {
    final key = (widget.inbox, _entry.id, _entry.item.digest);
    final revision = widget.inbox.store.favoritesRevision;
    if (_imageKey != key || (_imageFailed && _imageRevision != revision)) {
      _imageKey = key;
      _imageRevision = revision;
      _imageFailed = false;
      _image = widget.inbox
          .favoriteFileForExport(_entry)
          .then(
            (file) => file,
            onError: (Object error, StackTrace stack) {
              if (_imageKey == key) _imageFailed = true;
              Error.throwWithStackTrace(error, stack);
            },
          );
    }
    return _image!;
  }

  Future<void> _run(
    Future<bool> Function() action, {
    String? success,
    String fallback = '操作失败，请重试',
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final done = await action();
      if (mounted && done && success != null) showAppMessage(context, success);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = userError(error, fallback: fallback));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openImage() async {
    if (_busy) return;
    File? file;
    await _run(() async {
      file = await widget.inbox.favoriteFileForExport(_entry);
      return true;
    }, fallback: '无法打开附件，请重试');
    if (!mounted || file == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (viewerContext) => ImageViewer(
          file: file!,
          name: _entry.item.name,
          onMenu: (point) => unawaited(_imageMenu(viewerContext, point)),
        ),
      ),
    );
  }

  Future<void> _imageMenu(BuildContext viewerContext, Offset point) async {
    final action = await showMessageActions(
      context: viewerContext,
      anchor: Rect.fromLTWH(point.dx, point.dy, 1, 1),
      actions: const [MessageAction('save', '另存为', Icons.save_alt_outlined)],
    );
    if (!mounted || action != 'save') return;
    await _run(
      () => _actions.saveFile(_entry),
      success: '文件已保存',
      fallback: '文件保存失败，请重试',
    );
  }

  Future<void> _locate() async {
    try {
      final original = await widget.inbox.store.loadEntry(
        _entry.originalMessageId,
      );
      if (!mounted || original == null || widget.onLocate == null) return;
      widget.onBack();
      widget.onLocate!(original);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = userError(error, fallback: '聊天记录加载失败，请重试'));
      }
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _deleting = true;
      _error = null;
    });
    try {
      if (await widget.onDelete() && mounted) widget.onBack();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = userError(error, fallback: '收藏操作失败，请重试'));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _deleting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.inbox,
    builder: (context, _) {
      if (!widget.inbox.favoriteEntries.any(
        (entry) => entry.id == widget.entry.id,
      )) {
        return AppPanel(
          title: '收藏详情',
          embedded: widget.embedded,
          onClose: requestBack,
          actions: [
            TextButton(
              onPressed: requestBack,
              child: Text(tr(context, '返回收藏')),
            ),
          ],
          child: Center(
            child: Text(
              tr(
                context,
                widget.inbox.store.deleted.contains(
                      widget.entry.originalMessageId,
                    )
                    ? '消息已删除'
                    : '已取消收藏',
              ),
            ),
          ),
        );
      }
      final item = _entry.item;
      final originalExists = widget.inbox.store.originalExists(_entry);
      final palette = ChatPalette.of(context);
      return PopScope(
        canPop: !_busy,
        child: AppPanel(
          key: ValueKey('favorite-detail-${_entry.id}'),
          title: tr(context, '收藏详情'),
          embedded: widget.embedded,
          onClose: requestBack,
          width: 720,
          height: 540,
          canClose: !_busy,
          actions: [
            TextButton.icon(
              key: const ValueKey('favorite-detail-copy'),
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await _actions.copy(_entry);
                      return true;
                    }, success: '已复制'),
              icon: const Icon(Icons.content_copy_outlined, size: 18),
              label: Text(tr(context, item.isFile ? '复制文件名' : '复制文字')),
            ),
            if (item.isFile) ...[
              TextButton.icon(
                key: const ValueKey('favorite-detail-open'),
                onPressed: _busy
                    ? null
                    : item.kind == MessageKind.image
                    ? _openImage
                    : () => _run(() async {
                        await _actions.openFile(_entry);
                        return true;
                      }, fallback: '无法打开附件，请重试'),
                icon: Icon(
                  item.kind == MessageKind.image
                      ? Icons.zoom_in_rounded
                      : Icons.open_in_new_rounded,
                  size: 18,
                ),
                label: Text(
                  tr(context, item.kind == MessageKind.image ? '查看原图' : '打开附件'),
                ),
              ),
              TextButton.icon(
                key: const ValueKey('favorite-detail-save'),
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => _actions.saveFile(_entry),
                        success: '文件已保存',
                        fallback: '文件保存失败，请重试',
                      ),
                icon: const Icon(Icons.save_alt_rounded, size: 18),
                label: Text(tr(context, '另存为')),
              ),
            ],
            TextButton.icon(
              key: const ValueKey('favorite-detail-export'),
              onPressed: _busy
                  ? null
                  : () => _run(
                      () => _actions.export([_entry]),
                      success: '已导出收藏',
                      fallback: '收藏导出失败，请重试',
                    ),
              icon: const Icon(Icons.archive_outlined, size: 18),
              label: Text(tr(context, '导出')),
            ),
            if (originalExists && widget.onLocate != null)
              TextButton.icon(
                key: const ValueKey('favorite-detail-locate'),
                onPressed: _busy ? null : _locate,
                icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                label: Text(tr(context, '定位原消息')),
              ),
            TextButton.icon(
              key: const ValueKey('favorite-detail-delete'),
              onPressed: _busy ? null : _delete,
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: Text(tr(context, '删除收藏')),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.embedded) ...[
                Row(
                  children: [
                    IconButton(
                      key: const ValueKey('favorite-detail-back'),
                      tooltip: tr(context, '返回收藏'),
                      onPressed: _busy ? null : requestBack,
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        tr(context, '收藏详情'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
              ],
              if (_error != null) AppStatusMessage(_error!),
              if (_busy && !_deleting) const LinearProgressIndicator(),
              Expanded(
                child: SingleChildScrollView(
                  key: const ValueKey('favorite-detail-content'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${item.originName} · ${tr(context, '收藏于 {date}', {'date': favoriteTimestamp(context, _entry.savedAt)})}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 18),
                      if (!item.isFile)
                        SelectionArea(
                          child: MessageText(
                            text: item.text,
                            onLink: (value) => unawaited(
                              _run(() async {
                                await PlatformBridge.openUrl(value);
                                return true;
                              }, fallback: '无法打开链接，请重试'),
                            ),
                          ),
                        ),
                      if (item.kind == MessageKind.image) ...[
                        LayoutBuilder(
                          builder: (context, bounds) => FutureBuilder<File>(
                            future: _imageFile(),
                            builder: (context, snapshot) {
                              if (snapshot.hasData) {
                                return Align(
                                  alignment: Alignment.centerLeft,
                                  child: AttachmentThumbnail(
                                    file: snapshot.data!,
                                    maxWidth: bounds.maxWidth,
                                    maxHeight: 400,
                                    semanticLabel: item.name,
                                    onTap: _busy ? null : _openImage,
                                  ),
                                );
                              }
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 28,
                                ),
                                child: Column(
                                  children: [
                                    Icon(
                                      Icons.image_not_supported_outlined,
                                      color: palette.muted,
                                      size: 36,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      tr(
                                        context,
                                        snapshot.hasError ? '附件暂不可用' : '加载中…',
                                      ),
                                    ),
                                    if (snapshot.hasError)
                                      TextButton(
                                        onPressed: _busy
                                            ? null
                                            : () => setState(
                                                () => _imageKey = null,
                                              ),
                                        child: Text(tr(context, '重试')),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 18),
                      ],
                      if (item.isFile) ...[
                        SelectableText(
                          item.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          formatBytes(item.size),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      if (!originalExists) ...[
                        const SizedBox(height: 20),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: palette.sidebar,
                            borderRadius: AppCorners.border,
                          ),
                          child: Text(
                            tr(context, '正在核对原消息状态'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
