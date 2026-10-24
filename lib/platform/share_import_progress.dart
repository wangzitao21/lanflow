import 'package:flutter/foundation.dart';

class ShareImportProgress {
  const ShareImportProgress({
    required this.id,
    this.name = '',
    this.fileIndex = 0,
    this.fileCount = 0,
    this.bytes = 0,
    this.totalBytes = 0,
    this.phase = 'copying',
  });

  factory ShareImportProgress.fromJson(Map<dynamic, dynamic> value) {
    int count(String key) =>
        ((value[key] as num?)?.toInt() ?? 0).clamp(0, 1 << 62);
    return ShareImportProgress(
      id: value['id'] as String? ?? '',
      name: value['name'] as String? ?? '',
      fileIndex: count('fileIndex'),
      fileCount: count('fileCount'),
      bytes: count('bytes'),
      totalBytes: count('totalBytes'),
      phase: value['phase'] as String? ?? 'copying',
    );
  }

  final String id, name, phase;
  final int fileIndex, fileCount, bytes, totalBytes;
  bool get canCancel => phase == 'copying' || phase == 'queued';
  double? get fraction => phase == 'copying' && totalBytes > 0
      ? (bytes / totalBytes).clamp(0.0, 1.0)
      : null;
}

class ShareImportTracker extends ValueNotifier<List<ShareImportProgress>> {
  ShareImportTracker() : super(const []);
  final _snapshots = <Set<String>>[];
  final _finished = <String>{};

  Set<String> beginSnapshot() {
    final changed = <String>{};
    _snapshots.add(changed);
    return changed;
  }

  void endSnapshot(Set<String> changed) => _snapshots.remove(changed);

  void update(ShareImportProgress progress) {
    if (progress.id.isEmpty) return;
    for (final snapshot in _snapshots) {
      snapshot.add(progress.id);
    }
    if (_finished.contains(progress.id)) return;
    final next = value.toList();
    final index = next.indexWhere((item) => item.id == progress.id);
    if (const {'cancelled', 'failed', 'completed'}.contains(progress.phase)) {
      if (index >= 0) next.removeAt(index);
      if (progress.phase != 'failed') {
        _finished.add(progress.id);
        if (_finished.length > 512) _finished.remove(_finished.first);
      }
    } else if (index >= 0) {
      if (next[index].phase == 'saving' && progress.phase != 'saving') return;
      if (next[index].phase == 'ready' && progress.canCancel) return;
      next[index] = progress;
    } else {
      next.add(progress);
    }
    value = List.unmodifiable(next);
  }
}
