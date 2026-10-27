import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/shared/app_dialogs.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';

class MessageConflictTile extends StatefulWidget {
  const MessageConflictTile({
    super.key,
    required this.inbox,
    required this.conflict,
  });
  final InboxController inbox;
  final MessageConflict conflict;
  @override
  State<MessageConflictTile> createState() => _MessageConflictTileState();
}

class _MessageConflictTileState extends State<MessageConflictTile> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = userError(error, fallback: '处理未完成，请重试'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final conflict = widget.conflict;
    final approved = await showDialog<bool>(
      context: context,
      builder: (_) => const AppConfirmDialog(
        title: '删除所有冲突版本？',
        message: '这条消息的所有版本将从会话中删除，并在联网后同步删除其他设备上的这条消息。',
        confirmLabel: '删除所有版本',
      ),
    );
    if (approved == true && mounted) {
      await _run(() => widget.inbox.deleteConflict(conflict));
    }
  }

  Future<void> _edit(MessageEditVersion version) async {
    if (_busy) return;
    final conflict = widget.conflict;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ConflictEditor(
        inbox: widget.inbox,
        conflict: conflict,
        version: version,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.conflict.item.isFile
              ? widget.conflict.item.name
              : tr(context, '消息版本冲突'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(tr(context, '多个设备分别修改了同一消息。选择要保留的版本，或编辑后采用。')),
        for (final version in widget.conflict.versions)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    version.editorName == '旧版设备'
                        ? tr(context, version.editorName)
                        : version.editorName,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (version.editedAt case final DateTime time)
                    Text(
                      '${MaterialLocalizations.of(context).formatShortDate(time.toLocal())} '
                      '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(time.toLocal()))}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (widget.conflict.item.isFile) SelectableText(version.name),
                  if (version.text.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: SelectableText(version.text),
                    ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        key: ValueKey('use-version-${version.id}'),
                        onPressed: _busy
                            ? null
                            : () => _run(
                                () => widget.inbox.resolveConflict(
                                  widget.conflict,
                                  versionId: version.id,
                                ),
                              ),
                        child: Text(tr(context, '采用此版本')),
                      ),
                      TextButton(
                        key: ValueKey('edit-version-${version.id}'),
                        onPressed: _busy ? null : () => _edit(version),
                        child: Text(tr(context, '编辑后采用')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        if (_error != null)
          Text(
            tr(context, _error!),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            key: ValueKey('delete-conflict-${widget.conflict.id}'),
            onPressed: _busy ? null : _delete,
            child: Text(tr(context, '删除所有版本')),
          ),
        ),
      ],
    ),
  );
}

class _ConflictEditor extends StatefulWidget {
  const _ConflictEditor({
    required this.inbox,
    required this.conflict,
    required this.version,
  });
  final InboxController inbox;
  final MessageConflict conflict;
  final MessageEditVersion version;
  @override
  State<_ConflictEditor> createState() => _ConflictEditorState();
}

class _ConflictEditorState extends State<_ConflictEditor> {
  late final _text = TextEditingController(text: widget.version.text);
  late final _name = TextEditingController(text: widget.version.name);
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _text.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.inbox.resolveConflict(
        widget.conflict,
        text: _text.text,
        name: _name.text,
      );
      if (mounted) Navigator.pop(context);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = userError(error, fallback: '处理未完成，请重试'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AppPanel(
      title: '编辑后采用',
      width: 560,
      height: 430,
      canClose: !_busy,
      actions: [
        FilledButton(
          key: const ValueKey('save-conflict-edit'),
          onPressed: _busy ? null : _save,
          child: Text(tr(context, _busy ? '保存中…' : '采用修改后的版本')),
        ),
      ],
      child: ListView(
        children: [
          Text(tr(context, '保存后，此内容将替代当前列出的冲突版本，并同步到其他设备。')),
          const SizedBox(height: 12),
          if (widget.conflict.item.isFile)
            TextField(
              key: const ValueKey('conflict-edit-name'),
              controller: _name,
              enabled: !_busy,
              maxLength: 512,
              decoration: InputDecoration(labelText: tr(context, '文件名')),
            ),
          TextField(
            key: const ValueKey('conflict-edit-text'),
            controller: _text,
            enabled: !_busy,
            autofocus: true,
            minLines: 3,
            maxLines: null,
            maxLength: 20000,
            decoration: InputDecoration(
              labelText: tr(
                context,
                widget.conflict.item.isFile ? '添加说明' : '消息内容',
              ),
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
  );
}
