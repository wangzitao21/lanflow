import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/shared/app_strings.dart';

class RecoveryDestinationDialog extends StatefulWidget {
  const RecoveryDestinationDialog({super.key, required this.inbox});
  final InboxController inbox;
  @override
  State<RecoveryDestinationDialog> createState() =>
      _RecoveryDestinationDialogState();
}

class _RecoveryDestinationDialogState extends State<RecoveryDestinationDialog> {
  String _target = '';
  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('recovery-destination-dialog'),
    title: Text(tr(context, '恢复到哪里')),
    content: SizedBox(
      width: 400,
      height: MediaQuery.sizeOf(context).height * .4,
      child: ListView(
        children: [
          ListTile(
            key: const ValueKey('recovery-new-conversation'),
            leading: const Icon(Icons.add_comment_outlined),
            title: Text(tr(context, '恢复为新会话')),
            selected: _target.isEmpty,
            trailing: _target.isEmpty
                ? const Icon(Icons.check_circle_outline)
                : null,
            onTap: () => setState(() => _target = ''),
          ),
          for (final conversation in widget.inbox.conversations)
            ListTile(
              key: ValueKey('recovery-target-${conversation.id}'),
              leading: const Icon(Icons.chat_bubble_outline),
              title: Text(
                conversation.id == defaultConversationId &&
                        conversation.name == '发给自己'
                    ? tr(context, conversation.name)
                    : conversation.name,
              ),
              selected: _target == conversation.id,
              trailing: _target == conversation.id
                  ? const Icon(Icons.check_circle_outline)
                  : null,
              onTap: () => setState(() => _target = conversation.id),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr(context, '取消')),
      ),
      FilledButton(
        key: const ValueKey('confirm-recovery-target'),
        onPressed: () => Navigator.pop(context, _target),
        child: Text(tr(context, '恢复')),
      ),
    ],
  );
}
