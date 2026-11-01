import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';
import 'conversation_avatar.dart';

class ForwardMessageDialog extends StatefulWidget {
  const ForwardMessageDialog({
    super.key,
    required this.inbox,
    required this.item,
  });
  final InboxController inbox;
  final InboxItem item;

  @override
  State<ForwardMessageDialog> createState() => _ForwardMessageDialogState();
}

class _ForwardMessageDialogState extends State<ForwardMessageDialog> {
  String _query = '';
  String? _target, _error;
  bool _busy = false;
  late final _cut = widget.inbox.store.cutForward;

  Future<void> _send() async {
    if (_busy || _target == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.inbox.forwardMessage(widget.item, _target!, cut: _cut);
      if (mounted) Navigator.pop(context, _cut);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = userError(error, fallback: '转发失败，原消息已保留');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversations = widget.inbox.conversations
        .where(
          (c) =>
              c.id != widget.item.conversationId &&
              c.name.toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        key: const ValueKey('forward-message-dialog'),
        title: Text(tr(context, '转发到其他会话')),
        content: SizedBox(
          width: 400,
          height: MediaQuery.sizeOf(context).height * .45,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr(context, _cut ? '成功转发后，原消息移至回收站' : '转发后保留原消息')),
              const SizedBox(height: 12),
              TextField(
                enabled: !_busy,
                decoration: InputDecoration(
                  hintText: tr(context, '搜索会话'),
                  prefixIcon: const Icon(Icons.search),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: conversations.isEmpty
                    ? Center(child: Text(tr(context, '没有可转发的会话')))
                    : ListView.builder(
                        itemCount: conversations.length,
                        itemBuilder: (context, index) {
                          final c = conversations[index];
                          return ListTile(
                            key: ValueKey('forward-target-${c.id}'),
                            leading: ConversationAvatar(
                              id: c.id,
                              avatar: c.avatar,
                              color: c.avatarColor,
                            ),
                            title: Text(
                              c.id == defaultConversationId && c.name == '发给自己'
                                  ? tr(context, c.name)
                                  : c.name,
                            ),
                            selected: _target == c.id,
                            trailing: _target == c.id
                                ? const Icon(Icons.check_circle_outline)
                                : null,
                            onTap: _busy
                                ? null
                                : () => setState(() => _target = c.id),
                          );
                        },
                      ),
              ),
              if (_error != null)
                Text(
                  tr(context, _error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(tr(context, '取消')),
          ),
          FilledButton(
            key: const ValueKey('confirm-forward'),
            onPressed: _busy || _target == null ? null : _send,
            child: Text(tr(context, _busy ? '处理中…' : '转发')),
          ),
        ],
      ),
    );
  }
}
