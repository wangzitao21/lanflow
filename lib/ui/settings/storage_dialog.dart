import 'package:lanflow/ui/shared/chat_theme.dart';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';
import 'package:lanflow/ui/shared/app_feedback.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/app_dialogs.dart';
import 'recovered_files_panel.dart';

class StorageDialog extends StatefulWidget {
  const StorageDialog({super.key, required this.inbox, this.embedded = false});
  final InboxController inbox;
  final bool embedded;
  @override
  State<StorageDialog> createState() => _StorageDialogState();
}

class _StorageDialogState extends State<StorageDialog> {
  Map<String, dynamic>? stats;
  String? error;
  String? notice;
  bool busy = false;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _changeLocation() async {
    if (busy || widget.inbox.relocateStorage == null) return;
    String? target;
    try {
      if (Platform.isAndroid) {
        final support = await getApplicationSupportDirectory();
        final external = await getExternalStorageDirectories() ?? [];
        if (!mounted) return;
        target = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(tr(context, '选择存储位置')),
            children: [
              SimpleDialogOption(
                onPressed: () => Navigator.pop(
                  context,
                  p.join(support.parent.path, 'LanFlowData'),
                ),
                child: Text(tr(context, '内部存储 · 应用数据目录')),
              ),
              for (var index = 0; index < external.length; index++)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(
                    context,
                    p.join(external[index].path, 'LanFlowData'),
                  ),
                  child: Text(
                    tr(context, '外部存储 {count} · 应用专用目录', {'count': index + 1}),
                  ),
                ),
            ],
          ),
        );
      } else {
        final folder = await getDirectoryPath(
          confirmButtonText: tr(context, '选择文件夹'),
        );
        if (folder != null) {
          target = p.basename(folder).toLowerCase() == 'lanflow'
              ? folder
              : p.join(folder, 'LanFlow');
        }
      }
      if (target == null || !mounted) return;
      final destination = target;
      final migrate = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr(context, '更改存储位置')),
          scrollable: true,
          content: SizedBox(
            width: 480,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr(context, '新位置')),
                const SizedBox(height: 8),
                SelectableText(destination),
                const SizedBox(height: 20),
                Text(tr(context, '迁移原数据：保留聊天记录、图片、文件、草稿和设备绑定，校验成功后移除旧副本。')),
                const SizedBox(height: 12),
                Text(
                  tr(
                    context,
                    '在新位置重新开始：创建空白资料，旧位置的数据保留；为避免旧消息重新同步，其他设备需要重新绑定。',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr(context, '取消')),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, '在新位置重新开始')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(context, '迁移原数据')),
            ),
          ],
        ),
      );
      if (migrate == null || !mounted) return;
      setState(() {
        busy = true;
        error = null;
      });
      await widget.inbox.relocateStorage!(destination, migrate);
    } on Object catch (e) {
      if (mounted) {
        setState(() => error = userError(e, fallback: '无法更改存储位置，请检查空间和权限'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _backup() async {
    final backup = widget.inbox.backupStorage;
    if (busy || backup == null) return;
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final name = 'LanFlow-backup-$stamp.zip';
    Directory? temporary;
    try {
      String? path;
      if (Platform.isAndroid) {
        temporary = await (await getTemporaryDirectory()).createTemp(
          'lanflow-backup-',
        );
        path = p.join(temporary.path, name);
      } else {
        final selected = await getSaveLocation(
          suggestedName: name,
          acceptedTypeGroups: [
            XTypeGroup(
              label: tr(context, 'LanFlow 备份'),
              extensions: const ['zip'],
            ),
          ],
        );
        path = selected?.path;
      }
      if (path == null || !mounted) return;
      setState(() {
        busy = true;
        error = null;
      });
      await backup(path);
    } on Object catch (e) {
      if (mounted) {
        setState(() => error = userError(e, fallback: '备份未完成，请检查空间和权限'));
      }
    } finally {
      if (temporary != null && await temporary.exists()) {
        await temporary.delete(recursive: true);
      }
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _restore() async {
    final restore = widget.inbox.restoreStorage;
    if (busy || restore == null) return;
    Directory? temporary;
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: tr(context, 'LanFlow 备份'),
            extensions: const ['zip'],
            mimeTypes: const ['application/zip', 'application/octet-stream'],
          ),
        ],
      );
      if (file == null || !mounted) return;
      String archive = file.path;
      if (!await File(archive).exists()) {
        temporary = await (await getTemporaryDirectory()).createTemp(
          'lanflow-restore-',
        );
        archive = p.join(temporary.path, 'backup.zip');
        final output = File(archive).openWrite();
        try {
          await output.addStream(file.openRead());
        } finally {
          await output.close();
        }
      }
      String? target;
      if (!mounted) return;
      if (Platform.isAndroid) {
        final support = await getApplicationSupportDirectory();
        target = p.join(
          support.parent.path,
          'LanFlowRestored-${randomToken(6)}',
        );
      } else {
        final folder = await getDirectoryPath(
          confirmButtonText: tr(context, '选择恢复位置'),
        );
        if (folder != null) {
          target = p.join(
            folder,
            'LanFlowRestored-${DateTime.now().millisecondsSinceEpoch}',
          );
        }
      }
      if (target == null || !mounted) return;
      final destination = target;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr(context, '恢复完整备份')),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr(context, '校验通过后切换到恢复的数据，当前数据保留在原位置。备份中的设备身份和绑定也会恢复。')),
              const SizedBox(height: 12),
              SelectableText(destination),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, '取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(context, '恢复到新位置')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() {
        busy = true;
        error = null;
      });
      await restore(archive, destination);
    } on Object catch (e) {
      if (mounted) {
        setState(() => error = userError(e, fallback: '恢复未完成，请检查备份文件和存储空间'));
      }
    } finally {
      if (temporary != null && await temporary.exists()) {
        await temporary.delete(recursive: true);
      }
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _cleanup() async {
    final cleanup = widget.inbox.cleanupStorage;
    if (busy || cleanup == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppConfirmDialog(
        title: tr(context, '清理未使用附件？'),
        confirmLabel: tr(context, '清理'),
        destructive: false,
        message: tr(context, '仅清理未被消息、收藏、回收站、草稿或传输任务使用的附件。保留聊天内容和可恢复的记录。'),
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      await cleanup(false);
      if (mounted) {
        setState(() => busy = false);
        await _load();
      }
    } on Object catch (e) {
      if (mounted) setState(() => error = userError(e, fallback: '清理未完成，请重试'));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool clear = false}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      final result = await widget.inbox.store.storageStats(
        clearPreviews: clear,
      );
      if (mounted) {
        setState(() {
          stats = result;
          if (clear) {
            notice = result['skipped'] == 0 ? '缓存已清理' : '部分缓存正在使用，请稍后再试';
          }
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() => error = userError(e, fallback: '操作失败，请重试'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _size(String label, String key) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(child: Text(tr(context, label))),
        Text(formatBytes(stats?[key] as int? ?? 0)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final content = stats == null && busy
        ? const Center(child: CircularProgressIndicator())
        : stats == null && error != null
        ? AppEmptyState(
            title: '暂时无法读取存储信息',
            icon: Icons.storage_outlined,
            action: TextButton(
              onPressed: () => _load(),
              child: Text(tr(context, '重试')),
            ),
          )
        : Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: ListView(
              padding: const EdgeInsets.only(right: 10),
              controller: _scroll,
              children: [
                Text(
                  tr(context, '存储位置'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SelectableText(
                  widget.inbox.lan.store.directory.path,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  tr(
                    context,
                    '图片和视频放在 media，其他附件放在 files；保留原名和原始内容。消息、草稿与设置存放在 system。',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    tr(context, '查看具体路径'),
                    style: const TextStyle(fontSize: AppTypography.compact),
                  ),
                  children: [
                    SelectableText(
                      tr(context, '消息数据库：{path}', {
                        'path': p.join(
                          widget.inbox.store.directory.path,
                          'system',
                          'messages.sqlite3',
                        ),
                      }),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      tr(context, '图片和视频：{path}', {
                        'path': p.join(
                          widget.inbox.store.directory.path,
                          'media',
                        ),
                      }),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      tr(context, '其他文件：{path}', {
                        'path': p.join(
                          widget.inbox.store.directory.path,
                          'files',
                        ),
                      }),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('change-storage-location'),
                    onPressed: busy || widget.inbox.relocateStorage == null
                        ? null
                        : _changeLocation,
                    icon: const Icon(Icons.folder_open_outlined),
                    label: Text(tr(context, '更改位置')),
                  ),
                ),
                const Divider(height: 24),
                Text(
                  tr(context, '本机占用 {size}', {
                    'size': formatBytes(stats?['total'] as int? ?? 0),
                  }),
                  style: const TextStyle(
                    fontSize: AppTypography.title,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                _size('附件', 'blobs'),
                _size('缓存', 'cache'),
                _size('未完成的传输', 'partial'),
                _size('聊天记录', 'database'),
                _size('恢复的文件', 'recovered'),
                _size('其他数据', 'other'),
                if ((stats?['recovered'] as int? ?? 0) > 0)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('view-recovered-files'),
                      onPressed: busy
                          ? null
                          : () => showDialog<void>(
                              context: context,
                              builder: (_) => RecoveredFilesPanel(
                                directory: Directory(
                                  p.join(
                                    widget.inbox.store.directory.path,
                                    'system',
                                    'recovered',
                                  ),
                                ),
                              ),
                            ),
                      icon: const Icon(Icons.folder_open_outlined),
                      label: Text(tr(context, '查看恢复文件')),
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: busy || (stats?['cache'] as int? ?? 0) == 0
                      ? null
                      : () => _load(clear: true),
                  icon: const Icon(Icons.cleaning_services_outlined),
                  label: Text(tr(context, '清理缓存')),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('cleanup-unused-attachments'),
                      onPressed: busy || widget.inbox.cleanupStorage == null
                          ? null
                          : _cleanup,
                      icon: const Icon(Icons.auto_delete_outlined),
                      label: Text(tr(context, '清理未使用附件')),
                    ),
                  ],
                ),
                const Divider(height: 24),
                Text(
                  tr(context, '备份与恢复'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  tr(context, '完整备份包含消息、收藏、原始附件、草稿、设置和设备绑定。恢复时会先校验，并保留当前数据。'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('backup-storage'),
                      onPressed: busy || widget.inbox.backupStorage == null
                          ? null
                          : _backup,
                      icon: const Icon(Icons.backup_outlined),
                      label: Text(tr(context, '导出完整备份')),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('restore-storage'),
                      onPressed: busy || widget.inbox.restoreStorage == null
                          ? null
                          : _restore,
                      icon: const Icon(Icons.restore_outlined),
                      label: Text(tr(context, '从备份恢复')),
                    ),
                  ],
                ),
              ],
            ),
          );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null) AppStatusMessage(error!),
        if (notice != null) AppStatusMessage(notice!, error: false),
        if (busy && stats != null) const LinearProgressIndicator(),
        Expanded(child: content),
      ],
    );
    final actions = [
      TextButton(
        onPressed: busy ? null : () => _load(),
        child: Text(tr(context, '刷新')),
      ),
    ];
    return AppPanel(
      embedded: widget.embedded,
      title: '存储管理',
      width: 560,
      height: 500,
      actions: actions,
      child: body,
    );
  }
}
