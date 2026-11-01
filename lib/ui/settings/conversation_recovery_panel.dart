import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/chat/recovery_destination_dialog.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/shared/app_feedback.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';

class ConversationRecoveryPanel extends StatefulWidget {
  const ConversationRecoveryPanel({super.key, required this.inbox});
  final InboxController inbox;
  @override
  State<ConversationRecoveryPanel> createState() =>
      _ConversationRecoveryPanelState();
}

class _ConversationRecoveryPanelState extends State<ConversationRecoveryPanel> {
  final _items = <RecoveryItem>[];
  bool _loading = false, _busy = false, _more = false, _again = false;
  Map<String, dynamic>? _cursor;
  String? _error;
  int _revision = -1;
  @override
  void initState() {
    super.initState();
    widget.inbox.addListener(_changed);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.inbox.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (_revision == widget.inbox.store.revision) {
      if (mounted) setState(() {});
      return;
    }
    if (_loading || _busy) {
      _again = true;
    } else {
      unawaited(_load());
    }
  }

  Future<void> _load({bool append = false}) async {
    if (_loading) return;
    final revision = widget.inbox.store.revision;
    setState(() {
      _loading = true;
      _error = null;
      _again = false;
    });
    try {
      final page = await widget.inbox.store.recoveryPage(
        after: append ? _cursor : null,
      );
      if (!mounted) return;
      setState(() {
        if (!append) _items.clear();
        _items.addAll(
          (page['items'] as List).map((v) => RecoveryItem.fromJson(v as Map)),
        );
        _more = page['more'] == true;
        _cursor = (page['cursor'] as Map?)?.cast<String, dynamic>();
        _revision = revision;
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = userError(e, fallback: '无法加载待恢复内容，请重试'));
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_again && !_busy) unawaited(_load());
      }
    }
  }

  Future<void> _act(RecoveryItem item, {bool discard = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (discard) {
        await widget.inbox.discardRecovery(item);
      } else {
        final target = await showDialog<String>(
          context: context,
          builder: (_) => RecoveryDestinationDialog(inbox: widget.inbox),
        );
        if (!mounted || target == null) return;
        await widget.inbox.recoverMessage(
          item,
          conversation: target.isEmpty ? null : target,
        );
      }
      if (mounted) await _load();
    } on Object catch (e) {
      if (mounted) setState(() => _error = userError(e, fallback: '恢复失败，请重试'));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_again) unawaited(_load());
      }
    }
  }

  Future<void> _draft(String id) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final target = await showDialog<String>(
        context: context,
        builder: (_) => RecoveryDestinationDialog(inbox: widget.inbox),
      );
      if (!mounted || target == null) return;
      await widget.inbox.recoverDraft(
        id,
        conversation: target.isEmpty ? null : target,
      );
    } on Object catch (e) {
      if (mounted) setState(() => _error = userError(e, fallback: '恢复失败，请重试'));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_again) unawaited(_load());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final drafts = widget.inbox.recoveryDrafts;
    return PopScope(
      canPop: !_busy,
      child: AppPanel(
        title: '待恢复内容',
        width: 600,
        height: 540,
        canClose: !_busy,
        actions: [
          TextButton(
            onPressed: _busy || _loading ? null : _load,
            child: Text(tr(context, '刷新')),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr(context, '这些消息来自已删除的会话。可移入现有会话，或恢复为独立会话。')),
            const SizedBox(height: 12),
            if (_error != null) AppStatusMessage(_error!),
            if (_loading) const LinearProgressIndicator(),
            Expanded(
              child: _items.isEmpty && !_loading && drafts.isEmpty
                  ? AppEmptyState(
                      title: '暂无待恢复内容',
                      icon: Icons.restore_outlined,
                    )
                  : ListView.builder(
                      key: const ValueKey('conversation-recovery-list'),
                      itemCount:
                          drafts.length + _items.length + (_more ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index < drafts.length) {
                          final id = drafts[index];
                          return ListTile(
                            title: Text(
                              widget.inbox.store.conversations[id]!.name,
                            ),
                            subtitle: Text(tr(context, '本机未发送的草稿和附件')),
                            trailing: TextButton(
                              key: ValueKey('recover-draft-$id'),
                              onPressed: _busy ? null : () => _draft(id),
                              child: Text(tr(context, '恢复草稿…')),
                            ),
                          );
                        }
                        final messageIndex = index - drafts.length;
                        if (messageIndex == _items.length) {
                          return TextButton(
                            onPressed: _loading || _busy
                                ? null
                                : () => _load(append: true),
                            child: Text(tr(context, '加载更多')),
                          );
                        }
                        final entry = _items[messageIndex];
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SelectableText(
                                  entry.item.isFile
                                      ? entry.item.name
                                      : entry.item.text,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '${entry.conversationName} · ${entry.item.originName} · ${entry.item.createdAt.toLocal().toString().substring(0, 16)}',
                                ),
                                if (entry.versions > 1)
                                  Text(tr(context, '多个修改版本将一并恢复')),
                                if (!entry.available)
                                  Text(tr(context, '附件尚未就绪，请同步后重试')),
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    TextButton(
                                      key: ValueKey(
                                        'recover-message-${entry.item.id}',
                                      ),
                                      onPressed: _busy || !entry.available
                                          ? null
                                          : () => _act(entry),
                                      child: Text(tr(context, '恢复…')),
                                    ),
                                    TextButton(
                                      key: ValueKey(
                                        'discard-recovery-${entry.item.id}',
                                      ),
                                      onPressed: _busy
                                          ? null
                                          : () => _act(entry, discard: true),
                                      child: Text(tr(context, '移至回收站')),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
