import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';

class MessageInlineEditor extends StatelessWidget {
  const MessageInlineEditor({
    super.key,
    required this.text,
    this.name,
    required this.saving,
    this.error,
    required this.onSave,
    required this.onCancel,
  });
  final TextEditingController text;
  final TextEditingController? name;
  final bool saving;
  final String? error;
  final VoidCallback onSave, onCancel;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 420,
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
          if (saving ||
              text.value.composing.isValid &&
                  !text.value.composing.isCollapsed) {
            return;
          }
          final selection = text.selection;
          final start = selection.isValid ? selection.start : text.text.length;
          final end = selection.isValid ? selection.end : text.text.length;
          text.value = TextEditingValue(
            text: text.text.replaceRange(start, end, '\n'),
            selection: TextSelection.collapsed(offset: start + 1),
          );
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!saving) onCancel();
        },
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (name != null) ...[
            TextField(
              key: const ValueKey('message-edit-name'),
              controller: name,
              autofocus: true,
              enabled: !saving,
              maxLength: 512,
              decoration: InputDecoration(
                labelText: tr(context, '文件名'),
                counterText: '',
              ),
            ),
            const SizedBox(height: 8),
          ],
          TextField(
            key: const ValueKey('message-edit-text'),
            controller: text,
            autofocus: name == null,
            enabled: !saving,
            minLines: 1,
            maxLines: 10,
            maxLength: 20000,
            style: const TextStyle(fontSize: ChatMetrics.messageFontSize),
            decoration: InputDecoration(
              hintText: name == null ? null : tr(context, '添加说明'),
              counterText: '',
              border: InputBorder.none,
              filled: false,
            ),
          ),
          if (error != null)
            Text(
              tr(context, error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                onPressed: saving ? null : onCancel,
                child: Text(tr(context, '取消')),
              ),
              TextButton(
                key: const ValueKey('message-edit-save'),
                onPressed: saving ? null : onSave,
                child: Text(tr(context, saving ? '保存中…' : '保存')),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
