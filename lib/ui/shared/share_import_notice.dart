import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/platform/platform_bridge.dart';
import 'package:lanflow/platform/share_import_progress.dart';

import 'app_feedback.dart';
import 'app_strings.dart';
import 'chat_theme.dart';

class ShareImportNotice extends StatefulWidget {
  const ShareImportNotice({super.key, this.progress, this.onCancel});
  final ValueListenable<List<ShareImportProgress>>? progress;
  final Future<bool> Function(String id)? onCancel;

  @override
  State<ShareImportNotice> createState() => _ShareImportNoticeState();
}

class _ShareImportNoticeState extends State<ShareImportNotice> {
  final _cancelling = <String>{};

  Future<void> _cancel(String id) async {
    if (!_cancelling.add(id)) return;
    setState(() {});
    try {
      await (widget.onCancel ?? PlatformBridge.cancelShare)(id);
    } on Object {
      if (mounted) showAppMessage(context, '无法取消导入，请重试');
    } finally {
      _cancelling.remove(id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<List<ShareImportProgress>>(
    valueListenable: widget.progress ?? PlatformBridge.shareImports,
    builder: (context, imports, _) {
      if (imports.isEmpty) return const SizedBox.shrink();
      final current = imports.firstWhere(
        (item) => item.phase != 'queued',
        orElse: () => imports.first,
      );
      final label = current.phase == 'saving' || current.phase == 'ready'
          ? tr(context, '正在保存分享…')
          : tr(context, '正在导入分享…');
      final palette = ChatPalette.of(context);
      return Material(
        key: const ValueKey('share-import-notice'),
        color: palette.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label),
                        if (current.name.isNotEmpty)
                          Text(
                            current.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (current.fileCount > 0)
                          Text(
                            tr(context, '文件 {index}/{count} · {size}', {
                              'index': current.fileIndex.clamp(
                                0,
                                current.fileCount,
                              ),
                              'count': current.fileCount,
                              'size': current.totalBytes > 0
                                  ? '${formatBytes(current.bytes)} / ${formatBytes(current.totalBytes)}'
                                  : formatBytes(current.bytes),
                            }),
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 12,
                            ),
                          ),
                        if (imports.length > 1)
                          Text(
                            tr(context, '另有 {count} 项分享等待处理', {
                              'count': imports.length - 1,
                            }),
                          ),
                      ],
                    ),
                  ),
                  if (current.canCancel)
                    TextButton(
                      key: ValueKey('cancel-share-${current.id}'),
                      onPressed: _cancelling.contains(current.id)
                          ? null
                          : () => _cancel(current.id),
                      child: Text(tr(context, '取消')),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: current.fraction),
            ],
          ),
        ),
      );
    },
  );
}
