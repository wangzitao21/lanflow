import 'package:flutter/material.dart';
import 'conversation_avatar.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/ui/shared/app_dialogs.dart';
import 'package:lanflow/ui/shared/app_feedback.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/avatar_choices.dart';

class ConversationDialogs {
  const ConversationDialogs({
    required this.inbox,
    required this.showDialog,
    required this.onCreated,
  });
  final InboxController inbox;
  final ShowAppDialog showDialog;
  final ValueChanged<String> onCreated;

  Future<void> create(BuildContext context) => _editName(context);

  Future<void> rename(BuildContext context, String id) =>
      _editName(context, id: id);

  Future<void> _editName(BuildContext context, {String? id}) async {
    final name = TextEditingController(
      text: id == null
          ? ''
          : inbox.conversations.firstWhere((c) => c.id == id).name,
    );
    var saving = false;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, change) {
          Future<void> save() async {
            if (saving || !inbox.ready || name.text.trim().isEmpty) return;
            change(() {
              saving = true;
              error = null;
            });
            try {
              final created = id == null
                  ? await inbox.createConversation(name.text)
                  : null;
              if (id != null) await inbox.renameConversation(id, name.text);
              if (dialogContext.mounted) {
                Navigator.pop(dialogContext);
                if (created != null) onCreated(created.id);
              }
            } on Object catch (failure) {
              if (context.mounted) {
                change(() {
                  saving = false;
                  error = userError(
                    failure,
                    fallback: id == null ? '创建失败，请重试' : '重命名失败，请重试',
                  );
                });
              }
            }
          }

          return PopScope(
            canPop: !saving,
            child: AlertDialog(
              title: Text(tr(context, id == null ? '新建会话' : '重命名会话')),
              scrollable: true,
              content: SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (error != null) AppStatusMessage(error!),
                    TextField(
                      key: const ValueKey('conversation-name'),
                      controller: name,
                      autofocus: true,
                      enabled: !saving,
                      maxLength: 40,
                      decoration: InputDecoration(
                        hintText: tr(context, '例如：工作、灵感、稍后看'),
                      ),
                      onChanged: (_) => change(() {}),
                      onSubmitted: (_) => save(),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(context),
                  child: Text(tr(context, '取消')),
                ),
                FilledButton(
                  onPressed: saving || !inbox.ready || name.text.trim().isEmpty
                      ? null
                      : save,
                  child: Text(
                    tr(
                      context,
                      saving
                          ? '保存中…'
                          : id == null
                          ? '创建'
                          : '保存',
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    name.dispose();
  }

  Future<T?> _appearanceSheet<T>(BuildContext context, WidgetBuilder builder) {
    if (AppLayout.desktop(context)) {
      return showDialog<T>(
        context: context,
        builder: (context) => Dialog(
          alignment: Alignment.center,
          insetPadding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 420,
            child: SingleChildScrollView(child: builder(context)),
          ),
        ),
      );
    }
    return showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) =>
          SafeArea(child: SingleChildScrollView(child: builder(context))),
    );
  }

  Future<void> avatar(BuildContext context, String id) async {
    var selected = inbox.conversationAvatar(id);
    var color = inbox.conversationAvatarColor(id);
    final result = await _appearanceSheet<bool>(
      context,
      (context) => StatefulBuilder(
        builder: (context, change) => Padding(
          key: const ValueKey('conversation-avatar-editor'),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr(context, '更换头像'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 20),
              AvatarOptionGrid(
                children: [
                  for (final entry in conversationIcons.entries)
                    Semantics(
                      selected: selected == entry.key,
                      child: InkWell(
                        key: ValueKey('conversation-avatar-${entry.key}'),
                        borderRadius: AppCorners.border,
                        onTap: () => change(() => selected = entry.key),
                        child: Column(
                          children: [
                            ConversationAvatar(
                              id: id,
                              avatar: entry.key,
                              color: color,
                              size: 48,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              tr(context, entry.value.$1),
                              style: TextStyle(
                                fontWeight: selected == entry.key
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Text(tr(context, '头像颜色')),
              const SizedBox(height: 12),
              AvatarColorChoices(
                selected: color,
                keyPrefix: 'conversation-avatar-color',
                onChanged: (value) => change(() => color = value),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr(context, '完成')),
              ),
              TextButton(
                onPressed: () => change(() {
                  selected = null;
                  color = null;
                }),
                child: Text(tr(context, '恢复默认头像')),
              ),
            ],
          ),
        ),
      ),
    );
    if (result == true) {
      await inbox.setConversationAvatar(id, selected, color: color);
    }
  }

  Future<void> delete(BuildContext context, String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AppConfirmDialog(
        title: '删除会话',
        confirmLabel: '删除',
        message: inbox.linkFavoriteDeletion
            ? '会话中的消息及对应收藏将移至回收站，已绑定设备会同步这些更改。'
            : '会话中的消息将移至回收站，收藏不受影响。已绑定设备会同步删除这些消息。',
      ),
    );
    if (confirmed == true) await inbox.deleteConversation(id);
  }
}
