import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/platform/platform_bridge.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/profile_avatar.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/shared/app_dialogs.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/inbox_labels.dart';
import 'sync_connection_editor.dart';
import 'device_avatar_editor.dart';

class DeviceDialogs {
  DeviceDialogs({
    required this.context,
    required this.inbox,
    required this.showDialog,
    required this.onError,
  });

  final BuildContext context;
  final InboxController inbox;
  final ShowAppDialog showDialog;
  final ValueChanged<String> onError;
  LanController get lan => inbox.lan;
  Color get muted => ChatPalette.of(context).muted;
  Future<void> _prompts = Future.value();

  String _status(SyncStatus? status) {
    return status?.online == true ? '已连接' : '离线';
  }

  Future<bool> confirmPairing(IncomingPrompt prompt) {
    if (prompt.code == null) return Future.value(true);
    final result = Completer<bool>();
    _prompts = _prompts.catchError((Object _) {}).then((_) async {
      if (!context.mounted) {
        result.complete(false);
        return;
      }
      result.complete(
        await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                scrollable: true,
                title: Text(
                  tr(context, '绑定 {name}', {'name': prompt.peer.name}),
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr(context, '仅绑定自己的设备，绑定后将共享全部聊天内容。')),
                    Text(tr(context, '绑定后自动连接彼此已绑定的设备，全部内容会自动同步。')),
                    SizedBox(height: 20),
                    Text(tr(context, '核对另一台设备上的验证码')),
                    SelectableText(
                      prompt.code!,
                      style: TextStyle(
                        fontSize: 32,
                        letterSpacing: 7,
                        color: brandGreen,
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(tr(context, '取消')),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(tr(context, '是我的设备，绑定')),
                  ),
                ],
              ),
            ) ??
            false,
      );
    });
    return result.future;
  }

  Future<void> _bind(Peer peer, {bool repair = false}) async {
    var busy = false;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => PopScope(
          canPop: !busy,
          child: AlertDialog(
            scrollable: true,
            title: Text(tr(context, '绑定 {name}', {'name': peer.name})),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr(context, '绑定后将共享全部聊天内容，请核对验证码。')),
                Text(tr(context, '绑定后自动连接彼此已绑定的设备，全部内容会自动同步。')),
                SizedBox(height: 18),
                SelectableText(
                  verificationCode(lan.identity.fingerprint, peer.fingerprint),
                  style: TextStyle(
                    fontSize: 32,
                    color: brandGreen,
                    letterSpacing: 6,
                  ),
                ),
                if (busy)
                  Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(tr(context, '请在另一台设备上确认这次绑定')),
                  ),
                if (error != null)
                  Text(
                    tr(context, error!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: Text(tr(context, '取消')),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        if (busy) return;
                        update(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          await lan.connect(peer, rePair: repair);
                          inbox.requestSync();
                          if (context.mounted) Navigator.pop(context);
                        } on Object catch (e) {
                          if (context.mounted) {
                            update(() {
                              busy = false;
                              error = userError(e, fallback: '绑定失败，请重试');
                            });
                          }
                        }
                      },
                child: Text(tr(context, busy ? '等待确认' : '绑定我的设备')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _manualDevice() async {
    final address = TextEditingController();
    String? error;
    var busy = false;
    Peer? found;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => PopScope(
          canPop: !busy,
          child: AlertDialog(
            scrollable: true,
            title: Text(tr(context, '添加我的设备')),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    enabled: !busy,
                    controller: address,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: tr(context, '设备地址'),
                      hintText: '192.168.5.8:53318',
                    ),
                  ),
                  if (error != null)
                    Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        tr(context, error!),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: Text(tr(context, '取消')),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        if (busy) return;
                        update(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          final peer = await lan.addAddress(address.text);
                          if (peer.inboxVersion < 2) {
                            throw StateError('请更新另一台设备上的 LanFlow');
                          }
                          found = peer;
                          if (context.mounted) Navigator.pop(context);
                        } on Object catch (e) {
                          if (context.mounted) {
                            update(() {
                              busy = false;
                              error = userError(e, fallback: '连接失败，请检查设备地址');
                            });
                          }
                        }
                      },
                child: Text(tr(context, busy ? '正在连接' : '继续')),
              ),
            ],
          ),
        ),
      ),
    );
    address.dispose();
    if (found != null && context.mounted) await _bind(found!);
  }

  Future<void> _addHub() async {
    final name = TextEditingController();
    final address = TextEditingController();
    final code = TextEditingController();
    String? error;
    var busy = false;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => PopScope(
          canPop: !busy,
          child: AppPanel(
            title: '添加 NAS',
            canClose: !busy,
            width: 450,
            height: 300,
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: Text(tr(context, '取消')),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        if (busy) return;
                        update(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          await inbox.addHub(
                            address.text,
                            code.text,
                            name.text,
                          );
                          if (context.mounted) Navigator.pop(context);
                        } on Object catch (e) {
                          if (context.mounted) {
                            update(() {
                              busy = false;
                              error = userError(
                                e,
                                fallback: '连接失败，请检查 NAS 地址和连接码',
                              );
                            });
                          }
                        }
                      },
                child: Text(tr(context, busy ? '正在连接' : '连接')),
              ),
            ],
            child: SizedBox(
              width: 450,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      enabled: !busy,
                      controller: name,
                      maxLength: 60,
                      decoration: InputDecoration(
                        labelText: tr(context, '名称'),
                        hintText: tr(context, '家里的 NAS'),
                      ),
                    ),
                    SizedBox(height: 10),
                    TextField(
                      enabled: !busy,
                      controller: address,
                      decoration: InputDecoration(
                        labelText: tr(context, 'NAS 地址'),
                        hintText: '192.168.5.10:53320',
                      ),
                    ),
                    SizedBox(height: 16),
                    TextField(
                      enabled: !busy,
                      controller: code,
                      obscureText: true,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: tr(context, '连接码'),
                        hintText: tr(context, '粘贴连接码'),
                      ),
                    ),
                    if (error != null)
                      Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Text(
                          tr(context, error!),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    name.dispose();
    address.dispose();
    code.dispose();
  }

  Future<bool> _confirmRemove(String name) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => AppConfirmDialog(
          title: '移除“$name”？',
          confirmLabel: '移除',
          message: '移除后将停止与它同步。本机已保存的消息和文件会保留，以后可以重新绑定。',
        ),
      ) ??
      false;

  String _deviceStatus(String key) {
    final status = inbox.statuses[key];
    return _status(status);
  }

  Future<void> show() => showDialog<void>(
    context: context,
    builder: (_) => DevicePanel(dialogs: this),
  );
}

class DevicePanel extends StatefulWidget {
  const DevicePanel({
    super.key,
    required this.dialogs,
    this.embedded = false,
    this.discoveryWindowRequest,
  });
  final DeviceDialogs dialogs;
  final bool embedded;
  final Future<void> Function(Duration)? discoveryWindowRequest;

  @override
  State<DevicePanel> createState() => _DevicePanelState();
}

class _DevicePanelState extends State<DevicePanel> with WidgetsBindingObserver {
  static const _discoveryDuration = Duration(seconds: 15);
  Timer? _discoveryRenewal;
  bool _foreground = true;
  bool _visible = false;
  bool _browsing = false;
  bool refreshing = false;
  String? error;
  final removing = <String>{};
  DeviceDialogs get dialogs => widget.dialogs;
  InboxController get inbox => dialogs.inbox;
  LanController get lan => inbox.lan;
  Color get muted => ChatPalette.of(context).muted;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    lan.addListener(_updateDiscoveryWindow);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Desktop sections remain mounted in an IndexedStack; their TickerMode
    // marks which one is visible. An offstage panel must not renew Wi-Fi locks.
    _visible = TickerMode.valuesOf(context).enabled;
    _updateDiscoveryWindow();
  }

  @override
  void didUpdateWidget(DevicePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dialogs.lan != lan) {
      oldWidget.dialogs.lan.removeListener(_updateDiscoveryWindow);
      lan.addListener(_updateDiscoveryWindow);
      _browsing = false;
    }
    if (oldWidget.discoveryWindowRequest != widget.discoveryWindowRequest) {
      _discoveryRenewal?.cancel();
      _discoveryRenewal = null;
    }
    _visible = TickerMode.valuesOf(context).enabled;
    _updateDiscoveryWindow();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateDiscoveryWindow();
  }

  void _updateDiscoveryWindow() {
    final browsing = mounted && _foreground && _visible && !lan.receivingPaused;
    final resumedBrowsing = browsing && !_browsing;
    _browsing = browsing;
    if (!browsing) {
      _discoveryRenewal?.cancel();
      _discoveryRenewal = null;
      return;
    }
    final request =
        widget.discoveryWindowRequest ??
        (Platform.isAndroid
            ? (Duration duration) =>
                  PlatformBridge.requestDiscoveryWindow(duration: duration)
            : null);
    if (request != null && _discoveryRenewal == null) {
      void renew() =>
          unawaited(request(_discoveryDuration).catchError((Object _) {}));
      renew();
      // Only keep the receive window open while the user browses devices.
      // Renewal does not broadcast, synchronize, or delay message delivery.
      _discoveryRenewal = Timer.periodic(
        const Duration(seconds: 10),
        (_) => renew(),
      );
    }
    if (resumedBrowsing) unawaited(lan.refresh().catchError((Object _) {}));
  }

  @override
  void dispose() {
    _discoveryRenewal?.cancel();
    lan.removeListener(_updateDiscoveryWindow);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget removeButton(
      String key,
      String name,
      Future<void> Function() action,
    ) => TextButton(
      key: ValueKey('remove-$key'),
      onPressed: removing.contains(key)
          ? null
          : () async {
              if (!await dialogs._confirmRemove(name) || !context.mounted) {
                return;
              }
              setState(() {
                removing.add(key);
                error = null;
              });
              try {
                await action();
              } on Object catch (e) {
                if (context.mounted) {
                  setState(() => error = userError(e, fallback: '移除未完成，请重试'));
                }
              } finally {
                if (context.mounted) setState(() => removing.remove(key));
              }
            },
      child: Text(tr(context, removing.contains(key) ? '移除中' : '移除')),
    );
    final content = AnimatedBuilder(
      animation: Listenable.merge([lan, inbox, inbox.activity]),
      builder: (context, _) {
        final nearby = lan.sortedPeers
            .where((peer) => peer.online && !lan.sessions.containsKey(peer.id))
            .toList();
        return ListView(
          children: [
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  tr(context, error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: InkWell(
                key: ValueKey('edit-device-avatar-${lan.identity.id}'),
                onTap: () => editDeviceAvatar(
                  context,
                  inbox,
                  lan.identity.id,
                  platform: Theme.of(context).platform.name.toLowerCase(),
                ),
                child: ProfileAvatar(inbox: inbox, local: true),
              ),
              title: Text(
                tr(context, '{name}（本机）', {
                  'name': lan.name.isEmpty ? tr(context, '本机') : lan.name,
                }),
              ),
              subtitle: SelectableText(
                lan.addresses.isEmpty
                    ? tr(context, '暂无局域网地址')
                    : lan.addresses.join('\n'),
              ),
            ),
            const Divider(height: 24),
            Text(
              tr(context, '已绑定设备'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (lan.sessions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  tr(context, '在另一台设备打开 LanFlow，然后在下方绑定。'),
                  style: TextStyle(color: muted),
                ),
              ),
            for (final id in lan.sessions.keys)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: InkWell(
                  key: ValueKey('edit-device-avatar-$id'),
                  onTap: () => editDeviceAvatar(
                    context,
                    inbox,
                    id,
                    platform: lan.peers[id]?.platform,
                  ),
                  child: ProfileAvatar(
                    inbox: inbox,
                    local: false,
                    deviceId: id,
                    platform: lan.peers[id]?.platform,
                  ),
                ),
                title: Text(endpointLabel(context, inbox, 'device:$id')),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr(context, dialogs._deviceStatus('device:$id'))),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: ValueKey('configure-device:$id'),
                      tooltip: tr(context, '重新设置'),
                      onPressed: () => showSyncConnectionEditor(
                        context,
                        inbox,
                        SyncTarget(
                          'device:$id',
                          endpointLabel(context, inbox, 'device:$id'),
                        ),
                      ),
                      icon: const Icon(Icons.settings_outlined),
                    ),
                    if (inbox.statuses['device:$id']?.errorCategory ==
                            'authentication' &&
                        lan.peers[id] != null)
                      TextButton(
                        onPressed: () =>
                            dialogs._bind(lan.peers[id]!, repair: true),
                        child: Text(tr(context, '重新绑定')),
                      ),
                    removeButton(
                      'device:$id',
                      endpointLabel(context, inbox, 'device:$id'),
                      () => inbox.removeDevice(id),
                    ),
                  ],
                ),
              ),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr(context, '附近设备'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  onPressed: refreshing
                      ? null
                      : () async {
                          setState(() {
                            refreshing = true;
                            error = null;
                          });
                          try {
                            await lan.refresh().timeout(
                              const Duration(seconds: 3),
                            );
                            await inbox.syncNow();
                          } on Object {
                            if (context.mounted) {
                              setState(() => error = '暂时无法刷新，稍后可再试');
                            }
                          } finally {
                            if (context.mounted) {
                              setState(() => refreshing = false);
                            }
                          }
                        },
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(tr(context, refreshing ? '刷新中' : '刷新')),
                ),
              ],
            ),
            if (nearby.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  tr(context, '暂无附近设备\n请确认两台设备连接同一网络。'),
                  style: TextStyle(color: muted),
                ),
              ),
            for (final peer in nearby)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: ProfileAvatar(
                  inbox: inbox,
                  local: false,
                  deviceId: peer.id,
                  platform: peer.platform,
                ),
                title: Text(inbox.deviceName(peer.id, peer.name)),
                subtitle: Text(
                  tr(
                    context,
                    peer.inboxVersion < 2 ? '请更新此设备上的 LanFlow' : '未绑定',
                  ),
                ),
                trailing: TextButton(
                  onPressed: peer.inboxVersion >= 2 && lan.ready
                      ? () => dialogs._bind(peer)
                      : null,
                  child: Text(tr(context, '绑定')),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: lan.ready ? dialogs._manualDevice : null,
                icon: const Icon(Icons.add_link),
                label: Text(tr(context, '通过地址添加设备')),
              ),
            ),
            if (lan.discoveryWarning != null)
              Text(
                tr(context, '未能发现设备，请通过地址添加'),
                style: TextStyle(color: muted),
              ),
            const Divider(height: 24),
            Text(
              tr(context, 'NAS（可选）'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final hub in inbox.store.hubs)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: InkWell(
                  key: ValueKey('edit-device-avatar-${hub.id}'),
                  onTap: () => editDeviceAvatar(
                    context,
                    inbox,
                    hub.id,
                    platform: 'linux',
                  ),
                  child: ProfileAvatar(
                    inbox: inbox,
                    local: false,
                    deviceId: hub.id,
                    platform: 'linux',
                  ),
                ),
                title: Text(hub.name),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${hub.url.host}:${hub.url.port}\n${tr(context, dialogs._deviceStatus(hub.key))}',
                    ),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: ValueKey('configure-${hub.key}'),
                      tooltip: tr(context, '重新设置'),
                      onPressed: () => showSyncConnectionEditor(
                        context,
                        inbox,
                        SyncTarget(hub.key, hub.name, isHub: true),
                      ),
                      icon: const Icon(Icons.settings_outlined),
                    ),
                    removeButton(hub.key, hub.name, () => inbox.removeHub(hub)),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: inbox.ready ? dialogs._addHub : null,
                icon: const Icon(Icons.add),
                label: Text(tr(context, '添加 NAS')),
              ),
            ),
          ],
        );
      },
    );
    return widget.embedded
        ? content
        : AppPanel(title: '我的设备', width: 600, height: 560, child: content);
  }
}
