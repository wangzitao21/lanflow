import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/device_avatar_choices.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';

Future<void> editDeviceAvatar(
  BuildContext context,
  InboxController inbox,
  String id, {
  String? platform,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _Editor(inbox: inbox, id: id, platform: platform),
);

class _Editor extends StatefulWidget {
  const _Editor({required this.inbox, required this.id, this.platform});
  final InboxController inbox;
  final String id;
  final String? platform;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late String? _preset = widget.inbox.deviceAvatarPreset(widget.id);
  late int? _color = widget.inbox.deviceAvatarColor(widget.id);
  late String _avatar = widget.inbox.deviceAvatar(widget.id) ?? '';
  bool _saving = false;
  String? _error;
  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.inbox.setDeviceAppearance(
        widget.id,
        avatar: _avatar,
        preset: _preset,
        color: _color,
      );
      if (mounted) Navigator.pop(context);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = userError(error, fallback: '保存失败，请重试'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AppPanel(
      title: '设备头像',
      width: 480,
      height: 180,
      canClose: !_saving,
      actions: [
        TextButton(
          onPressed: _saving
              ? null
              : () => setState(() {
                  _preset = null;
                  _color = null;
                  _avatar = '';
                }),
          child: Text(tr(context, '恢复默认头像')),
        ),
        FilledButton(
          key: const ValueKey('save-device-avatar'),
          onPressed: _saving ? null : _save,
          child: Text(tr(context, _saving ? '保存中…' : '完成')),
        ),
      ],
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DeviceAvatarChoices(
              preset: _preset,
              color: _color,
              platform: widget.platform,
              photo: _avatar.isNotEmpty,
              onPreset: _saving
                  ? null
                  : (value) => setState(() {
                      _preset = value;
                      _avatar = '';
                    }),
              onColor: _saving
                  ? null
                  : (value) => setState(() => _color = value),
            ),
            if (_error != null)
              Text(
                tr(context, _error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
  );
}
