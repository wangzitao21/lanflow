import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/shared/app_dialogs.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';

Future<void> showSyncConnectionEditor(
  BuildContext context,
  InboxController inbox,
  SyncTarget target,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => SyncConnectionEditor(inbox: inbox, target: target),
);

Future<bool> removeSyncConnection(
  BuildContext context,
  InboxController inbox,
  SyncTarget target,
) async {
  final approved = await showDialog<bool>(
    context: context,
    builder: (_) => AppConfirmDialog(
      title: tr(context, '移除连接“{name}”？', {'name': target.name}),
      message: '移除后停止与此设备同步。本机消息和文件会保留，以后可以重新添加。',
      confirmLabel: '移除连接',
    ),
  );
  if (approved != true) return false;
  try {
    if (target.isHub) {
      final hub = inbox.store.hubs
          .where((hub) => hub.key == target.key)
          .firstOrNull;
      if (hub != null) await inbox.removeHub(hub);
    } else {
      await inbox.removeDevice(target.key.substring('device:'.length));
    }
    return true;
  } on Object catch (error) {
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(tr(context, userError(error, fallback: '移除未完成，请重试'))),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr(context, '关闭')),
            ),
          ],
        ),
      );
    }
    return false;
  }
}

class SyncConnectionEditor extends StatefulWidget {
  const SyncConnectionEditor({
    super.key,
    required this.inbox,
    required this.target,
  });
  final InboxController inbox;
  final SyncTarget target;
  @override
  State<SyncConnectionEditor> createState() => _SyncConnectionEditorState();
}

class _SyncConnectionEditorState extends State<SyncConnectionEditor> {
  final _address = TextEditingController();
  final _name = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false, _pairAgain = false;
  String? _error, _notice;
  SyncEndpoint? get _hub => widget.inbox.store.hubs
      .where((hub) => hub.key == widget.target.key)
      .firstOrNull;
  String get _deviceId => widget.target.key.substring('device:'.length);

  @override
  void initState() {
    super.initState();
    _name.text = widget.target.name;
    if (widget.target.isHub) {
      _address.text = _hub?.url.toString() ?? '';
    } else {
      final peer = widget.inbox.lan.peers[_deviceId];
      if (peer != null) _address.text = '${peer.address}:${peer.port}';
    }
  }

  @override
  void dispose() {
    _address.dispose();
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool close = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await action();
      if (close && mounted) Navigator.pop(context);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = userError(error, fallback: '设置未保存，请重试'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _run(() async {
    if (widget.target.isHub) {
      final hub = _hub;
      if (hub == null) throw StateError('设备已移除');
      await widget.inbox.updateHub(
        hub,
        address: _address.text,
        name: _name.text,
        code: _code.text,
      );
    } else {
      await widget.inbox.updateDeviceAddress(_deviceId, _address.text);
      if (_pairAgain) {
        await widget.inbox.lan.connect(
          widget.inbox.lan.peers[_deviceId]!,
          rePair: true,
        );
        widget.inbox.requestSync(endpoint: widget.target.key, immediate: true);
      }
    }
  }, close: true);

  Future<void> _reset() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (_) => const AppConfirmDialog(
        title: '重新同步全部内容？',
        message: '将重新核对消息和附件，并重建已删除的传输任务。本机内容保留，手动暂停或取消的任务保持原状态。',
        confirmLabel: '重新同步',
        destructive: false,
      ),
    );
    if (approved == true && mounted) {
      await _run(() async {
        await widget.inbox.resetSync(widget.target.key);
        if (mounted) setState(() => _notice = '已重建同步记录，连接可用时继续同步');
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AppPanel(
      title: '重新设置连接',
      width: 500,
      height: 440,
      canClose: !_busy,
      actions: [
        FilledButton(
          key: const ValueKey('save-sync-connection'),
          onPressed: _busy ? null : _save,
          child: Text(tr(context, _busy ? '保存中…' : '保存设置')),
        ),
      ],
      child: ListView(
        children: [
          Text(
            widget.target.name,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          if (widget.target.isHub)
            TextField(
              key: const ValueKey('sync-connection-name'),
              controller: _name,
              enabled: !_busy,
              maxLength: 60,
              decoration: InputDecoration(labelText: tr(context, '名称')),
            ),
          TextField(
            key: const ValueKey('sync-connection-address'),
            controller: _address,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: tr(context, widget.target.isHub ? 'NAS 地址' : '设备地址'),
            ),
          ),
          const SizedBox(height: 12),
          if (widget.target.isHub)
            TextField(
              key: const ValueKey('sync-connection-code'),
              controller: _code,
              enabled: !_busy,
              obscureText: true,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: tr(context, '新的 NAS 连接码（留空保留原值）'),
              ),
            )
          else
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _pairAgain,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _pairAgain = value == true),
              title: Text(tr(context, '保存后重新绑定')),
              subtitle: Text(tr(context, '另一台设备需要确认；未确认时保留原绑定。')),
            ),
          if (_error != null)
            Text(
              tr(context, _error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_notice != null) Text(tr(context, _notice!)),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                key: const ValueKey('reset-sync-connection'),
                onPressed: _busy ? null : _reset,
                child: Text(tr(context, '重新同步')),
              ),
              TextButton(
                key: const ValueKey('remove-sync-connection'),
                onPressed: _busy
                    ? null
                    : () async {
                        if (await removeSyncConnection(
                              context,
                              widget.inbox,
                              widget.target,
                            ) &&
                            context.mounted) {
                          Navigator.pop(context);
                        }
                      },
                child: Text(tr(context, '移除连接')),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
