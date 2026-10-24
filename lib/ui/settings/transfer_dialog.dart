import 'package:flutter/material.dart';

import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/shared/motion.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';
import 'package:lanflow/ui/shared/app_feedback.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/inbox_labels.dart';

class TransferDialog extends StatefulWidget {
  const TransferDialog({super.key, required this.inbox, this.embedded = false});
  final InboxController inbox;
  final bool embedded;
  @override
  State<TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends State<TransferDialog> {
  String? error;
  bool _loading = true;
  bool _syncing = false;
  final Set<String> busy = {};
  String _scope = 'active';
  List<TransferTask> _history = [];
  int _historyOffset = 0;
  bool _historyMore = false;
  int _historyGeneration = 0;

  Future<void> _loadHistory({bool append = false}) async {
    if (append && _loading) return;
    final generation = ++_historyGeneration;
    setState(() {
      _loading = true;
      error = null;
    });
    try {
      final page = await widget.inbox.store.transferHistory(
        offset: append ? _historyOffset : 0,
      );
      final values = (page['items'] as List)
          .map(
            (v) => TransferTask.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList();
      if (mounted && generation == _historyGeneration) {
        setState(() {
          _history = {
            for (final task in [
              ...(append ? _history : <TransferTask>[]),
              ...values,
            ])
              task.key: task,
          }.values.toList();
          _historyOffset = page['nextOffset'] as int;
          _historyMore = page['more'] == true;
        });
      }
    } on Object catch (failure) {
      if (mounted && generation == _historyGeneration) {
        setState(() => error = userError(failure, fallback: '无法加载传输任务，请重试'));
      }
    } finally {
      if (mounted && generation == _historyGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_scope == 'completed') return _loadHistory();
    setState(() {
      _loading = true;
      error = null;
    });
    try {
      await widget.inbox.refreshTransfers();
    } on Object catch (e) {
      if (mounted) {
        setState(() => error = userError(e, fallback: '无法加载传输任务，请重试'));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sync() async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
      error = null;
    });
    try {
      await widget.inbox.syncNow();
    } on Object catch (e) {
      if (mounted) setState(() => error = userError(e, fallback: '同步未完成，请重试'));
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _action(TransferTask task, String action) async {
    final key = '${task.endpoint}:${task.direction}:${task.eventId}';
    if (!busy.add(key)) return;
    setState(() => error = null);
    try {
      await widget.inbox.controlTransfer(task, action);
    } on Object catch (e) {
      if (mounted) {
        setState(() => error = userError(e, fallback: '操作失败，请重试'));
      }
    } finally {
      busy.remove(key);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.inbox.activity,
    builder: (context, _) {
      final tasks = _scope == 'completed'
          ? _history
          : widget.inbox.transferTasks
                .where((task) => _scope != 'failed' || task.state == 'failed')
                .toList();
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final scope in [
                ('active', '进行中'),
                ('failed', '需重试'),
                ('completed', '最近完成'),
              ])
                ChoiceChip(
                  key: ValueKey('transfers-scope-${scope.$1}'),
                  label: Text(tr(context, scope.$2)),
                  selected: _scope == scope.$1,
                  onSelected: (_) {
                    setState(() {
                      _scope = scope.$1;
                      _historyGeneration++;
                      _loading = false;
                    });
                    if (_scope == 'completed') {
                      _loadHistory();
                    }
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (error != null) AppStatusMessage(error!),
          Expanded(
            child: tasks.isEmpty
                ? _loading
                      ? const AppEmptyState(
                          title: '正在读取传输任务…',
                          icon: Icons.sync_alt_rounded,
                        )
                      : AppEmptyState(
                          title: error != null
                              ? '无法加载传输任务'
                              : _scope == 'completed'
                              ? '暂无已完成的传输'
                              : _scope == 'failed'
                              ? '暂无失败的传输'
                              : '暂无待传输的附件',
                          icon: Icons.sync_alt_rounded,
                          description: error == null ? '发送附件后，可在这里查看进度。' : null,
                          action: error == null
                              ? null
                              : TextButton(
                                  onPressed: _refresh,
                                  child: Text(tr(context, '重试')),
                                ),
                        )
                : ListView.separated(
                    itemCount:
                        tasks.length +
                        (_scope == 'completed' && _historyMore ? 1 : 0),
                    separatorBuilder: (_, index) => const Divider(height: 24),
                    itemBuilder: (context, index) {
                      if (index == tasks.length) {
                        return TextButton(
                          onPressed: _loading
                              ? null
                              : () => _loadHistory(append: true),
                          child: Text(tr(context, _loading ? '加载中…' : '加载更多')),
                        );
                      }
                      final task = tasks[index];
                      final disabled = busy.contains(
                        '${task.endpoint}:${task.direction}:${task.eventId}',
                      );
                      final status = widget.inbox.statuses[task.endpoint];
                      final label =
                          task.state == 'completed' ||
                              task.stopped ||
                              task.state == 'failed' ||
                              status?.busy != true
                          ? task.label
                          : task.direction == 'upload'
                          ? '正在上传'
                          : '正在下载';
                      return Column(
                        key: ValueKey(
                          'transfer-${task.endpoint}-${task.eventId}-${task.direction}',
                        ),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.item.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${endpointLabel(context, widget.inbox, task.endpoint)} · ${tr(context, label)}',
                          ),
                          const SizedBox(height: 8),
                          TweenAnimationBuilder<double>(
                            tween: Tween(
                              begin: task.progress,
                              end: task.progress,
                            ),
                            duration: AppMotion.duration(context),
                            builder: (_, progress, _) =>
                                LinearProgressIndicator(value: progress),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${formatBytes(task.transferred)} / ${formatBytes(task.item.size)}',
                          ),
                          if (task.bytesPerSecond > 0 && status?.busy == true)
                            Text(
                              '${formatBytes(task.bytesPerSecond.round())}/s · ${tr(context, '约剩 {seconds} 秒', {'seconds': ((task.item.size - task.transferred) / task.bytesPerSecond).ceil()})}',
                            ),
                          if (task.completedAt != null)
                            Text(
                              MaterialLocalizations.of(
                                context,
                              ).formatFullDate(task.completedAt!.toLocal()),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          if (task.state != 'completed' &&
                              (task.error != null || status?.error != null))
                            Text(
                              tr(
                                context,
                                userError(
                                  task.error ?? status!.error,
                                  fallback: '传输失败，请重试',
                                ),
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          if (task.state != 'completed')
                            Wrap(
                              spacing: 8,
                              children: [
                                if (task.stopped || task.state == 'failed')
                                  TextButton(
                                    onPressed: disabled
                                        ? null
                                        : () => _action(task, 'retry'),
                                    child: Text(
                                      tr(
                                        context,
                                        task.state == 'paused' ? '继续传输' : '重试',
                                      ),
                                    ),
                                  )
                                else
                                  TextButton(
                                    onPressed: disabled
                                        ? null
                                        : () => _action(task, 'pause'),
                                    child: Text(tr(context, '暂停')),
                                  ),
                                if (task.state != 'cancelled')
                                  TextButton(
                                    onPressed: disabled
                                        ? null
                                        : () => _action(task, 'cancel'),
                                    child: Text(tr(context, '取消传输')),
                                  ),
                              ],
                            ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      );
      final actions = [
        if (_scope == 'completed')
          TextButton(
            onPressed: _loading ? null : _refresh,
            child: Text(tr(context, '刷新')),
          ),
        TextButton(
          onPressed: widget.inbox.syncing || _syncing ? null : _sync,
          child: Text(tr(context, _syncing ? '同步中…' : '立即同步')),
        ),
      ];
      return AppPanel(
        embedded: widget.embedded,
        title: '传输任务',
        width: 640,
        height: 500,
        actions: actions,
        child: content,
      );
    },
  );
}
