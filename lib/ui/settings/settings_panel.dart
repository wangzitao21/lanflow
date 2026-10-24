import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lanflow/ui/shared/app_feedback.dart';

import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/ui/settings/storage_dialog.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/device_avatar.dart';
import 'package:lanflow/ui/shared/motion.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/devices/device_dialogs.dart';
import 'package:lanflow/ui/settings/transfer_dialog.dart';

enum SettingsPage {
  preferences('设置', Icons.tune_rounded),
  profile('设备资料', Icons.badge_outlined),
  devices('我的设备', Icons.devices_outlined),
  transfers('传输任务', Icons.sync_alt_rounded),
  storage('存储管理', Icons.storage_outlined);

  const SettingsPage(this.title, this.icon);
  final String title;
  final IconData icon;
}

class SettingsPanel extends StatefulWidget {
  const SettingsPanel({
    super.key,
    required this.inbox,
    this.initialPage = SettingsPage.preferences,
  });
  final InboxController inbox;
  final SettingsPage initialPage;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  late final _name = TextEditingController(text: widget.inbox.lan.name);
  late String _avatar = widget.inbox.lan.ready
      ? widget.inbox.deviceAvatar(widget.inbox.lan.identity.id) ?? ''
      : '';
  late final _pages = [widget.initialPage];
  SettingsPage get _page => _pages.last;
  bool _saving = false;
  bool _picking = false;
  bool _changingAppearance = false;
  bool _changingLanguage = false;
  bool _changingFavoriteDeletion = false;
  String? _error;
  InboxController get inbox => widget.inbox;
  bool get _canBack => _pages.length > 1;
  late final _deviceDialogs = DeviceDialogs(
    context: context,
    inbox: inbox,
    showDialog: <T>({required context, required builder}) =>
        showDialog<T>(context: context, builder: builder),
    onError: (message) {
      if (mounted) setState(() => _error = message);
    },
  );

  @override
  void initState() {
    super.initState();
    inbox.addListener(_inboxChanged);
  }

  void _inboxChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    inbox.removeListener(_inboxChanged);
    _name.dispose();
    super.dispose();
  }

  void _go(SettingsPage page) {
    if (_page == page || _saving || _picking) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _error = null;
      if (AppLayout.split(context)) {
        _pages
          ..clear()
          ..add(page);
      } else {
        _pages.add(page);
      }
    });
  }

  void _back() {
    if (_saving || _picking) return;
    if (AppLayout.split(context) && _page == SettingsPage.profile) {
      _go(SettingsPage.preferences);
      return;
    }
    if (_canBack) {
      setState(() {
        _error = null;
        _pages.removeLast();
      });
    } else {
      Navigator.pop(context);
    }
  }

  void _cancelProfile() {
    if (_saving || _picking) return;
    _name.text = inbox.lan.name;
    _avatar = inbox.lan.identityReady
        ? inbox.deviceAvatar(inbox.lan.identity.id) ?? ''
        : '';
    _back();
  }

  Future<void> _appearance(String value) async {
    if (_changingAppearance) return;
    setState(() {
      _changingAppearance = true;
      _error = null;
    });
    try {
      await inbox.setAppearance(value);
    } on Object {
      if (mounted) setState(() => _error = '外观设置未保存，请重试');
    } finally {
      if (mounted) setState(() => _changingAppearance = false);
    }
  }

  Future<void> _language(String value) async {
    if (_changingLanguage || value == inbox.language.value) return;
    setState(() {
      _changingLanguage = true;
      _error = null;
    });
    try {
      await inbox.setLanguage(value);
    } on Object {
      if (mounted) setState(() => _error = '语言设置未保存，请重试');
    } finally {
      if (mounted) setState(() => _changingLanguage = false);
    }
  }

  Future<void> _copyDiagnostics() async {
    try {
      await Clipboard.setData(
        ClipboardData(
          text: const JsonEncoder.withIndent('  ').convert(inbox.diagnostics()),
        ),
      );
      if (mounted) showAppMessage(context, '诊断信息已复制');
    } on Object {
      if (mounted) setState(() => _error = '复制失败，请重试');
    }
  }

  Future<void> _favoriteDeletion(bool value) async {
    if (_changingFavoriteDeletion) return;
    setState(() {
      _changingFavoriteDeletion = true;
      _error = null;
    });
    try {
      await inbox.setLinkFavoriteDeletion(value);
    } on Object {
      if (mounted) setState(() => _error = '收藏设置未保存，请重试');
    } finally {
      if (mounted) setState(() => _changingFavoriteDeletion = false);
    }
  }

  Future<void> _pickAvatar() async {
    if (_picking || _saving) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: tr(context, '头像'),
            extensions: ['jpg', 'jpeg', 'png', 'webp'],
            mimeTypes: ['image/*'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > 20 * 1024 * 1024) {
        throw const FormatException('请选择 20 MB 以内的图片');
      }
      final codec = await ui.instantiateImageCodec(
        await file.readAsBytes(),
        targetWidth: 512,
        allowUpscaling: false,
      );
      late ui.Image source;
      try {
        source = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
      try {
        final side = source.width < source.height
            ? source.width
            : source.height;
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawImageRect(
          source,
          Rect.fromLTWH(
            (source.width - side) / 2,
            (source.height - side) / 2,
            side.toDouble(),
            side.toDouble(),
          ),
          const Rect.fromLTWH(0, 0, 256, 256),
          Paint()..filterQuality = FilterQuality.high,
        );
        final picture = recorder.endRecording();
        try {
          final image = await picture.toImage(256, 256);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            if (mounted && bytes != null) {
              setState(
                () => _avatar = base64Encode(bytes.buffer.asUint8List()),
              );
            }
          } finally {
            image.dispose();
          }
        } finally {
          picture.dispose();
        }
      } finally {
        source.dispose();
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = userError(error, fallback: '无法读取图片，请重新选择'));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _save() async {
    if (_saving || _picking || !inbox.lan.ready || _name.text.trim().isEmpty) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await inbox.updateProfile(_name.text.trim(), avatar: _avatar);
      if (mounted) {
        setState(() => _saving = false);
        _back();
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = userError(error, fallback: '保存失败，请重试');
        });
      }
    }
  }

  Widget _navigation(SettingsPage page, {bool sidebar = false}) => ListTile(
    key: ValueKey('settings-page-${page.name}'),
    shape: RoundedRectangleBorder(borderRadius: AppCorners.border),
    contentPadding: EdgeInsets.symmetric(horizontal: sidebar ? 12 : 0),
    selected: sidebar && page == _page,
    selectedTileColor: ChatPalette.of(context).selected,
    leading: Icon(page.icon, size: 21),
    title: Text(
      tr(context, page == SettingsPage.preferences ? '偏好设置' : page.title),
      style: TextStyle(fontSize: sidebar ? 13 : 15),
    ),
    trailing: sidebar ? null : const Icon(Icons.chevron_right, size: 20),
    onTap: () => _go(page),
  );

  Widget _profile() {
    final p = ChatPalette.of(context);
    return ListView(
      key: const PageStorageKey('profile-form'),
      children: [
        Row(
          children: [
            Tooltip(
              message: tr(context, '更换头像'),
              child: InkWell(
                onTap: _picking || _saving ? null : _pickAvatar,
                borderRadius: AppCorners.border,
                child: Stack(
                  children: [
                    DeviceAvatar(
                      image: _avatar,
                      size: 64,
                      local: true,
                      platform: AppLayout.desktop(context)
                          ? 'windows'
                          : 'android',
                    ),
                    const Positioned(
                      right: 0,
                      bottom: 0,
                      child: CircleAvatar(
                        radius: 11,
                        backgroundColor: brandGreen,
                        child: Icon(Icons.edit, size: 12, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(context, '头像'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (_picking) ...[
                    const SizedBox(height: 4),
                    Text(
                      tr(context, '处理中…'),
                      style: TextStyle(
                        fontSize: AppTypography.caption,
                        color: p.muted,
                      ),
                    ),
                  ],
                  if (_avatar.isNotEmpty)
                    TextButton(
                      onPressed: _saving || _picking
                          ? null
                          : () => setState(() => _avatar = ''),
                      child: Text(tr(context, '恢复默认头像')),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _name,
          maxLength: 60,
          enabled: !_saving,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: tr(context, '设备名称')),
        ),
      ],
    );
  }

  Widget _preferences() {
    return ListView(
      key: const PageStorageKey('preferences-form'),
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: DeviceAvatar(
            image: inbox.lan.identityReady
                ? inbox.deviceAvatar(inbox.lan.identity.id)
                : null,
            size: 48,
            local: true,
            platform: AppLayout.desktop(context) ? 'windows' : 'android',
          ),
          title: Text(
            inbox.lan.name.isEmpty ? tr(context, '本机') : inbox.lan.name,
          ),
          subtitle: Text(tr(context, '编辑设备名称与头像')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _go(SettingsPage.profile),
        ),
        const Divider(height: 32),
        if (!AppLayout.split(context)) ...[
          _navigation(SettingsPage.devices),
          _navigation(SettingsPage.transfers),
          const Divider(height: 24),
        ],
        Text(tr(context, '外观'), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in [
                ('system', '跟随系统'),
                ('light', '浅色'),
                ('dark', '深色'),
              ])
                ChoiceChip(
                  key: ValueKey('appearance-${option.$1}'),
                  label: Text(tr(context, option.$2)),
                  selected: inbox.appearance.value == option.$1,
                  onSelected: _changingAppearance || !inbox.ready
                      ? null
                      : (_) => _appearance(option.$1),
                ),
            ],
          ),
        ),
        if (!AppLayout.split(context)) ...[
          const Divider(height: 24),
          _navigation(SettingsPage.storage),
        ],
        const Divider(height: 32),
        Text(tr(context, '语言'), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in [('zh', '简体中文'), ('en', 'English')])
              ChoiceChip(
                key: ValueKey('language-${option.$1}'),
                label: Text(option.$2),
                selected: inbox.language.value == option.$1,
                onSelected: _changingLanguage || !inbox.ready
                    ? null
                    : (_) => _language(option.$1),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          tr(context, '切换后立即生效'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const Divider(height: 32),
        Text(tr(context, '收藏'), style: Theme.of(context).textTheme.titleMedium),
        SwitchListTile.adaptive(
          key: const ValueKey('link-favorite-deletion'),
          contentPadding: EdgeInsets.zero,
          title: Text(tr(context, '会话与收藏联动删除')),
          subtitle: Text(tr(context, '默认互不影响。开启后，删除一处也会删除对应的另一处。')),
          value: inbox.linkFavoriteDeletion,
          onChanged: !inbox.ready || _changingFavoriteDeletion
              ? null
              : _favoriteDeletion,
        ),
        const Divider(height: 32),
        Text(
          tr(context, '后台运行'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        ListenableBuilder(
          listenable: inbox.lan,
          builder: (context, _) => SwitchListTile.adaptive(
            key: const ValueKey('automatic-sync'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr(context, '自动同步')),
            subtitle: Text(
              tr(
                context,
                inbox.lan.receivingPaused ? '已暂停收发，恢复后继续同步' : '与已绑定设备自动同步消息和文件',
              ),
            ),
            value: !inbox.lan.receivingPaused,
            onChanged: !inbox.ready
                ? null
                : (enabled) => inbox.lan.setReceivingPaused(!enabled),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          tr(
            context,
            AppLayout.desktop(context)
                ? '关闭窗口后仍在托盘运行，可继续接收消息。'
                : '保持后台服务运行可接收消息，从最近任务中划掉应用会停止服务。',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const Divider(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('copy-diagnostics'),
            onPressed: _copyDiagnostics,
            icon: const Icon(Icons.copy_outlined, size: 18),
            label: Text(tr(context, '复制诊断信息')),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final sidebar = AppLayout.split(context);
    final desktopPanel = !AppLayout.fullPage(context);
    final profileActions = <Widget>[
      TextButton(
        onPressed: _saving || _picking ? null : _cancelProfile,
        child: Text(tr(context, '取消')),
      ),
      FilledButton(
        onPressed:
            _saving || _picking || !inbox.lan.ready || _name.text.trim().isEmpty
            ? null
            : _save,
        child: Text(tr(context, _saving ? '保存中' : '保存')),
      ),
    ];
    final content = switch (_page) {
      SettingsPage.preferences => _preferences(),
      SettingsPage.profile => _profile(),
      SettingsPage.devices => DevicePanel(
        dialogs: _deviceDialogs,
        embedded: true,
      ),
      SettingsPage.transfers => TransferDialog(inbox: inbox, embedded: true),
      SettingsPage.storage => StorageDialog(inbox: inbox, embedded: true),
    };
    return PopScope(
      canPop: !_canBack && !_saving && !_picking,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _canBack) {
          if (_page == SettingsPage.profile) {
            _cancelProfile();
          } else {
            _back();
          }
        }
      },
      child: AppPanel(
        key: const ValueKey('settings-panel'),
        canClose: !_saving && !_picking,
        title: tr(context, sidebar ? '设置' : _page.title),
        width: 760,
        height: 500,
        backLabel: tr(context, '返回'),
        onBack: !sidebar && _canBack
            ? (_page == SettingsPage.profile ? _cancelProfile : _back)
            : null,
        onClose: () {
          if (!_saving && !_picking) Navigator.pop(context);
        },
        actions: !desktopPanel && _page == SettingsPage.profile
            ? profileActions
            : const [],
        child: Column(
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  tr(context, _error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (sidebar) ...[
                    Container(
                      width: 176,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: ChatPalette.of(context).sidebar,
                        borderRadius: AppCorners.border,
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: ListView(
                          children: [
                            for (final page in SettingsPage.values)
                              _navigation(page, sidebar: true),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 24),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (sidebar) ...[
                          Text(
                            tr(
                              context,
                              _page == SettingsPage.preferences
                                  ? '偏好设置'
                                  : _page.title,
                            ),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 20),
                        ],
                        Expanded(
                          child: PageReveal(identity: _page, child: content),
                        ),
                        if (desktopPanel && _page == SettingsPage.profile)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                profileActions[0],
                                const SizedBox(width: 8),
                                profileActions[1],
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
