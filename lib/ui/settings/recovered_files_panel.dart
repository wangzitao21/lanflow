import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/network/models.dart';
import '../../platform/platform_bridge.dart';
import '../shared/app_strings.dart';
import '../shared/user_feedback.dart';

class RecoveredFilesPanel extends StatefulWidget {
  const RecoveredFilesPanel({super.key, required this.directory});
  final Directory directory;

  @override
  State<RecoveredFilesPanel> createState() => _RecoveredFilesPanelState();
}

class _RecoveredFilesPanelState extends State<RecoveredFilesPanel> {
  late final _files = _read();
  String? _error;

  Future<List<(File, int)>> _read() async {
    final files = <(File, int)>[];
    if (!await widget.directory.exists()) return files;
    final boundary = await widget.directory.resolveSymbolicLinks();
    await for (final entity in widget.directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final resolved = await entity.resolveSymbolicLinks();
      if (!p.isWithin(boundary, resolved)) continue;
      files.add((entity, await entity.length()));
    }
    files.sort(
      (a, b) => p.basename(a.$1.path).compareTo(p.basename(b.$1.path)),
    );
    return files;
  }

  Future<void> _open(File file) async {
    try {
      await PlatformBridge.openFile(file.path);
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = userError(error, fallback: '暂时无法打开，请另存文件后选择应用'),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr(context, '恢复的文件')),
    content: SizedBox(
      width: 520,
      height: 360,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr(context, '这里保留了附件被外部修改后的副本，清理缓存不会删除它们。')),
          if (_error != null)
            Text(
              tr(context, _error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<List<(File, int)>>(
              future: _files,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text(tr(context, '暂时无法读取存储信息')));
                }
                final files = snapshot.data;
                if (files == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (files.isEmpty) {
                  return Center(child: Text(tr(context, '暂无恢复文件')));
                }
                return ListView.builder(
                  itemCount: files.length,
                  itemBuilder: (context, index) => ListTile(
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(p.basename(files[index].$1.path)),
                    subtitle: Text(formatBytes(files[index].$2)),
                    onTap: () => _open(files[index].$1),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr(context, '关闭')),
      ),
    ],
  );
}
