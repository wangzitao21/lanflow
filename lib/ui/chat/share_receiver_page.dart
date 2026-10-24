import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/platform/platform_bridge.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';
import 'conversation_avatar.dart';

class ShareSelectionResult {
  const ShareSelectionResult({this.conversation, this.deferred = false});
  final String? conversation;
  final bool deferred;
}

class ShareReceiverPage extends StatefulWidget {
  const ShareReceiverPage({
    super.key,
    required this.inbox,
    required this.payload,
    required this.onSend,
  });
  final InboxController inbox;
  final Map<String, dynamic> payload;
  final Future<void> Function(Map<String, dynamic>) onSend;
  @override
  State<ShareReceiverPage> createState() => _ShareReceiverPageState();
}

class _ShareReceiverPageState extends State<ShareReceiverPage> {
  final _search = TextEditingController();
  late final _comment = TextEditingController(
    text: widget.payload['comment'] as String? ?? '',
  );
  late String? _target = widget.payload['conversationId'] as String?;
  bool _sending = false, _sent = false, _locked = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _locked = _target != null;
  }

  @override
  void dispose() {
    _search.dispose();
    _comment.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending || _target == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _sending = true;
      _locked = true;
      _error = null;
    });
    try {
      await widget.onSend({
        ...widget.payload,
        'conversationId': _target,
        'comment': _comment.text,
      });
      if (mounted) setState(() => _sent = true);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = userError(error, fallback: '发送失败，请重试'));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _stay() {
    if (_target != null) widget.inbox.selectConversation(_target!);
    Navigator.pop(context, ShareSelectionResult(conversation: _target));
  }

  @override
  Widget build(BuildContext context) {
    final palette = ChatPalette.of(context);
    final conversations = widget.inbox.conversations
        .where(
          (item) =>
              item.name.toLowerCase().contains(_search.text.toLowerCase()),
        )
        .toList();
    final target = widget.inbox.conversations
        .where((item) => item.id == _target)
        .firstOrNull;
    return PopScope(
      canPop: !_sending && !_locked && _target == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _sent) _stay();
        if (!didPop && !_locked && _target != null) {
          setState(() => _target = null);
        }
      },
      child: Scaffold(
        key: const ValueKey('share-receiver-page'),
        appBar: AppBar(
          title: Text(tr(context, _sent ? '已发送' : '选择一个会话')),
          automaticallyImplyLeading: !_sending && !_locked && _target == null,
          leading: !_locked && _target != null
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _target = null),
                )
              : null,
        ),
        body: SafeArea(
          child: _sent
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.check_circle_outline_rounded,
                          color: brandGreen,
                          size: 76,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          tr(context, '已发送'),
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 32),
                        FilledButton(
                          onPressed: () async {
                            Navigator.pop(context);
                            await PlatformBridge.returnToShareSource();
                          },
                          child: Text(tr(context, '返回原应用')),
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: _stay,
                          child: Text(tr(context, '留在 LanFlow')),
                        ),
                      ],
                    ),
                  ),
                )
              : Column(
                  children: [
                    if ((widget.payload['recoveredMissing'] as int? ?? 0) > 0)
                      Padding(
                        key: const ValueKey('recovered-share-notice'),
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Text(
                          tr(context, '已恢复上次分享中保存完成的内容，剩余 {count} 个文件请重新分享', {
                            'count': widget.payload['recoveredMissing'] as int,
                          }),
                        ),
                      ),
                    if (!_locked && _target == null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: TextField(
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: tr(context, '搜索会话'),
                          ),
                        ),
                      ),
                    if (_target == null)
                      Expanded(
                        child: ListView.builder(
                          itemCount: conversations.length,
                          itemBuilder: (context, index) {
                            final item = conversations[index];
                            return ListTile(
                              key: ValueKey('share-to-${item.id}'),
                              leading: ConversationAvatar(
                                id: item.id,
                                avatar: widget.inbox.store
                                    .preference(item.id)
                                    .avatar,
                              ),
                              title: Text(item.name),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () {
                                FocusManager.instance.primaryFocus?.unfocus();
                                setState(() => _target = item.id);
                              },
                            );
                          },
                        ),
                      )
                    else
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                tr(context, '发送给'),
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: ConversationAvatar(
                                  id: _target!,
                                  avatar: widget.inbox.store
                                      .preference(_target!)
                                      .avatar,
                                ),
                                title: Text(
                                  target?.name ?? tr(context, '发给自己'),
                                ),
                                trailing: !_locked
                                    ? const Icon(Icons.chevron_right)
                                    : null,
                                onTap: _locked
                                    ? null
                                    : () => setState(() => _target = null),
                              ),
                              Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: palette.sidebar,
                                  borderRadius: AppCorners.border,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if ((widget.payload['text'] as String? ??
                                            '')
                                        .isNotEmpty)
                                      SelectableText(
                                        widget.payload['text'] as String,
                                      ),
                                    for (final file
                                        in widget.payload['files'] as List? ??
                                            [])
                                      ListTile(
                                        contentPadding: EdgeInsets.zero,
                                        leading: const Icon(
                                          Icons.insert_drive_file_outlined,
                                        ),
                                        title: Text(
                                          (file as Map)['name'] as String? ??
                                              '',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 20),
                              TextField(
                                controller: _comment,
                                enabled: !_locked,
                                maxLength: 20000,
                                maxLines: 3,
                                decoration: InputDecoration(
                                  hintText: tr(context, '添加留言（可选）'),
                                  counterText: '',
                                ),
                              ),
                              if (_error != null)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  child: Text(
                                    tr(context, _error!),
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                ),
                              FilledButton(
                                key: const ValueKey('share-send'),
                                onPressed: _sending ? null : _send,
                                child: Text(
                                  tr(context, _sending ? '发送中' : '发送'),
                                ),
                              ),
                              if (_error != null && !_sending)
                                TextButton(
                                  onPressed: () => Navigator.pop(
                                    context,
                                    const ShareSelectionResult(deferred: true),
                                  ),
                                  child: Text(tr(context, '稍后重试')),
                                ),
                              if (!_locked)
                                TextButton(
                                  onPressed: () =>
                                      setState(() => _target = null),
                                  child: Text(tr(context, '取消')),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}
