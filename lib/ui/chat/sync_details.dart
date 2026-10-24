import 'package:flutter/material.dart';

import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/chat/sync_feedback.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/inbox_labels.dart';

class SyncDetails extends StatelessWidget {
  const SyncDetails({
    super.key,
    required this.inbox,
    required this.entry,
    required this.onDevices,
    required this.onTransfers,
  });
  final InboxController inbox;
  final InboxEntry entry;
  final VoidCallback onDevices;
  final VoidCallback onTransfers;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([inbox, inbox.activity]),
    builder: (context, _) {
      final details = inbox.copyDetails(entry);
      return AppPanel(
        title: '同步详情',
        width: 480,
        height: 380,
        actions: [
          TextButton(onPressed: onDevices, child: Text(tr(context, '我的设备'))),
          if (details.isNotEmpty)
            FilledButton(
              onPressed: onTransfers,
              child: Text(tr(context, '查看传输任务')),
            ),
        ],
        child: ListView(
          children: [
            Text(
              entry.item.isFile ? entry.item.name : entry.item.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 20),
            if (details.isEmpty) Text(tr(context, '暂无已绑定设备')),
            for (final detail in details)
              if (detail.state == CopyState.failed)
                SyncIssueTile(
                  key: ValueKey(detail.target.key),
                  inbox: inbox,
                  target: detail.target,
                  label: detail.label,
                  detail: detail.detail,
                  onDevices: onDevices,
                )
              else
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    detail.target.isHub
                        ? Icons.dns_outlined
                        : Icons.devices_outlined,
                  ),
                  title: Text(syncTargetLabel(context, inbox, detail.target)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr(context, detail.label),
                        style: TextStyle(
                          color: detail.state == CopyState.failed
                              ? Theme.of(context).colorScheme.error
                              : null,
                        ),
                      ),
                      if (detail.detail != null)
                        Text(
                          tr(
                            context,
                            userError(
                              detail.detail,
                              fallback: '同步未完成，可在传输任务中重试',
                            ),
                          ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                  trailing: detail.state == CopyState.complete
                      ? Icon(
                          Icons.check_circle_outline,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                ),
          ],
        ),
      );
    },
  );
}
