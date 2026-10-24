import 'package:flutter/material.dart';

import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/inbox_labels.dart';

class SyncAttentionNotice extends StatelessWidget {
  const SyncAttentionNotice({
    super.key,
    required this.inbox,
    required this.onOpen,
  });
  final InboxController inbox;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: inbox.activity,
    builder: (context, _, _) {
      final problems = inbox.syncProblems;
      if (problems.isEmpty) return const SizedBox.shrink();
      final palette = ChatPalette.of(context);
      return Material(
        key: const ValueKey('sync-attention-notice'),
        color: palette.warning.withValues(alpha: .09),
        child: Padding(
          padding: const EdgeInsets.only(left: 16, right: 8),
          child: Row(
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 20,
                color: palette.warning,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr(context, '{count} 台设备同步需要处理', {'count': problems.length}),
                  style: TextStyle(
                    fontSize: AppTypography.compact,
                    color: palette.warning,
                  ),
                ),
              ),
              TextButton(
                key: const ValueKey('open-sync-problems'),
                onPressed: onOpen,
                style: TextButton.styleFrom(
                  foregroundColor: palette.warning,
                  minimumSize: const Size(72, 48),
                ),
                child: Text(tr(context, '查看问题')),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class SyncIssuesPanel extends StatelessWidget {
  const SyncIssuesPanel({
    super.key,
    required this.inbox,
    required this.onDevices,
    required this.onTransfers,
  });
  final InboxController inbox;
  final VoidCallback onDevices, onTransfers;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([inbox, inbox.activity]),
    builder: (context, _) {
      final problems = inbox.syncProblems;
      return AppPanel(
        title: '同步异常',
        width: 480,
        height: 380,
        actions: [
          TextButton(onPressed: onDevices, child: Text(tr(context, '我的设备'))),
          TextButton(onPressed: onTransfers, child: Text(tr(context, '传输任务'))),
        ],
        child: problems.isEmpty
            ? Center(child: Text(tr(context, '暂无需要处理的同步异常')))
            : ListView(
                children: [
                  Text(tr(context, '本机内容仍然保留。处理后会继续同步。')),
                  const SizedBox(height: 16),
                  for (final target in problems)
                    SyncIssueTile(
                      key: ValueKey(target.key),
                      inbox: inbox,
                      target: target,
                      detail: inbox.syncProblemDetail(target.key),
                      onDevices: onDevices,
                    ),
                ],
              ),
      );
    },
  );
}

class SyncIssueTile extends StatefulWidget {
  const SyncIssueTile({
    super.key,
    required this.inbox,
    required this.target,
    this.label = '同步失败',
    this.detail,
    this.onDevices,
  });
  final InboxController inbox;
  final SyncTarget target;
  final String label;
  final String? detail;
  final VoidCallback? onDevices;

  @override
  State<SyncIssueTile> createState() => _SyncIssueTileState();
}

class _SyncIssueTileState extends State<SyncIssueTile> {
  bool _busy = false;
  String? _error;

  Future<void> _retry() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.inbox.retrySync(widget.target.key);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = userError(error, fallback: '重试未完成，请稍后再试'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final problem = userError(widget.detail, fallback: '同步未完成，可在此重试');
    final requiresPairing =
        widget.onDevices != null &&
        (problem.contains('重新绑定') ||
            problem.contains('连接码') ||
            problem.contains('另一台设备上确认'));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              widget.target.isHub ? Icons.dns_outlined : Icons.devices_outlined,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  syncTargetLabel(context, widget.inbox, widget.target),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  tr(context, widget.label),
                  style: TextStyle(color: scheme.error),
                ),
                if (widget.detail != null)
                  Text(
                    tr(context, problem),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (_error != null)
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      tr(context, _error!),
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                TextButton.icon(
                  key: ValueKey('retry-sync-${widget.target.key}'),
                  onPressed:
                      _busy ||
                          widget.inbox.statuses[widget.target.key]?.busy == true
                      ? null
                      : requiresPairing
                      ? widget.onDevices
                      : _retry,
                  style: TextButton.styleFrom(minimumSize: const Size(96, 48)),
                  icon: Icon(
                    requiresPairing
                        ? Icons.link_rounded
                        : Icons.refresh_rounded,
                    size: 18,
                  ),
                  label: Text(
                    tr(
                      context,
                      requiresPairing
                          ? '重新绑定'
                          : _busy
                          ? '重试中…'
                          : '重试同步',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
