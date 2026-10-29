import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app.dart';
import 'core/inbox/inbox_controller.dart';
import 'core/inbox/inbox_store.dart';
import 'core/network/lan_controller.dart';
import 'core/storage/local_store.dart';
import 'core/storage/storage_location.dart';
import 'core/storage/storage_layout.dart';
import 'core/storage/storage_backup.dart';
import 'platform/platform_bridge.dart';
import 'platform/native_core.dart';
import 'core/network/models.dart';
import 'ui/shared/runtime_feedback.dart';
import 'ui/shared/app_root.dart';
import 'ui/chat/mobile_home.dart';

class RuntimeSession {
  RuntimeSession._(this.lan, this.inbox, this.network);
  final LanController lan;
  final InboxController inbox;
  final Future<void> network;
  VoidCallback? _activityListener;
  VoidCallback? _lanListener;
  bool _closed = false;
  bool get isClosed => _closed;

  static Future<RuntimeSession> open(
    Directory root, {
    Directory? receiveDirectory,
    String? name,
    bool enableDiscovery = true,
    int preferredPort = 53318,
    InternetAddress? bindAddress,
    RuntimeSession? recoverFrom,
  }) async {
    await StorageLayout.prepare(root);
    final lan = LanController(
      store: recoverFrom?.lan.ready == true
          ? _RecoveryLocalStore(root, recoverFrom!.lan)
          : LocalStore(root),
      receiveDirectory: receiveDirectory ?? StorageLayout.received(root),
      initialName: name,
      enableDiscovery: enableDiscovery,
      preferredPort: preferredPort,
      bindAddress: bindAddress,
      beforeDiscovery: PlatformBridge.requestDiscoveryWindow,
    );
    final inbox = InboxController(
      lan: lan,
      store: recoverFrom?.inbox.ready == true
          ? _RecoveryInboxStore(root, recoverFrom!.inbox.store)
          : InboxStore(root),
    );
    final network = lan.start();
    try {
      await inbox.store.loadPreferences();
      inbox.appearance.value = inbox.store.appearance;
      inbox.language.value = inbox.store.language;
    } on Object {
      /* start() displays a recoverable storage error. */
    }
    return RuntimeSession._(lan, inbox, network);
  }

  Future<void> start({bool acceptShares = true}) async {
    if (_closed) return;
    await inbox.start();
    if (_closed) return;
    await network;
    if (_closed) return;
    if (lan.ready &&
        inbox.ready &&
        !inbox.store.profiles.containsKey(lan.identity.id)) {
      await inbox.updateProfile(lan.name);
    }
    if (_closed) return;
    inbox.requestSync();
    if (acceptShares) await listenShares();
    if (_closed) return;
    if (lan.ready) {
      await PlatformBridge.setLanguage(
        inbox.language.value,
      ).catchError((Object _) {});
      if (_closed) return;
      await PlatformBridge.setSyncPaused(
        lan.receivingPaused,
      ).catchError((Object _) {});
      if (_closed) return;
      try {
        await PlatformBridge.startReceiver();
      } on Object {
        lan.error = '后台服务未开启，保持应用在前台即可收发';
      }
      if (_closed) {
        await PlatformBridge.stopReceiver().catchError((Object _) {});
        return;
      }
    }
    // Always publish the replacement session's initial state, including idle.
    // The Android service may still retain the preceding session's state.
    bool? active;
    _activityListener = () {
      final next = inbox.transferring;
      if (active != next) {
        active = next;
        unawaited(
          PlatformBridge.setTransferring(next).catchError((Object _) {}),
        );
      }
    };
    inbox.activity.addListener(_activityListener!);
    _activityListener!();
    var paused = lan.receivingPaused;
    _lanListener = () {
      if (paused != lan.receivingPaused) {
        paused = lan.receivingPaused;
        unawaited(
          PlatformBridge.setSyncPaused(paused).catchError((Object _) {}),
        );
      }
    };
    lan.addListener(_lanListener!);
  }

  Future<void> listenShares() => _closed
      ? Future.value()
      : PlatformBridge.listenShares(
          inbox.addShared,
          (error) => inbox.reportError('分享未保存完成：$error'),
        );

  Future<void> close() async {
    if (_closed) return;
    await inbox.commitPendingEdits();
    if (_closed) return;
    _closed = true;
    if (_activityListener != null) {
      inbox.activity.removeListener(_activityListener!);
    }
    if (_lanListener != null) lan.removeListener(_lanListener!);
    try {
      await network;
      await lan.close();
    } finally {
      try {
        await inbox.close();
      } finally {
        await PlatformBridge.stopReceiver().catchError((Object _) {});
      }
    }
  }

  void dispose() {
    inbox.dispose();
    lan.dispose();
  }
}

// Hydrate failed-close edits before the network controller binds its server,
// and before the inbox controller registers handlers or starts synchronization.
class _RecoveryLocalStore extends LocalStore {
  _RecoveryLocalStore(super.directory, LanController previous)
    : _previous = previous;
  LanController? _previous;
  @override
  Future<Map<String, dynamic>> load() async {
    final state = await super.load();
    final previous = _previous;
    if (previous == null) return state;
    final recovered = <String, dynamic>{
      ...state,
      'name': previous.name,
      'autoAcceptFiles': previous.autoAcceptFiles,
      'receivingPaused': previous.receivingPaused,
      'receiveDirectory': previous.receiveDirectory.path,
      'peers': previous.peers.values.map((peer) => peer.toJson()).toList(),
      'sessions': previous.sessions.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
      'messages': previous.messages.map((message) => message.toJson()).toList(),
    };
    _previous = null;
    return recovered;
  }
}

class _RecoveryInboxStore extends InboxStore {
  _RecoveryInboxStore(super.directory, InboxStore previous)
    : _previous = previous;
  InboxStore? _previous;
  @override
  Future<void> load({void Function(int loaded, int total)? onProgress}) async {
    await super.load(onProgress: onProgress);
    final previous = _previous;
    if (previous == null) return;
    drafts
      ..clear()
      ..addAll(previous.drafts);
    attachmentDrafts
      ..clear()
      ..addAll(
        previous.attachmentDrafts.map(
          (key, value) => MapEntry(key, List.of(value)),
        ),
      );
    hubs
      ..clear()
      ..addAll(previous.hubs);
    migrated
      ..clear()
      ..addAll(previous.migrated);
    conversationPreferences
      ..clear()
      ..addAll(previous.conversationPreferences);
    conversationOrder
      ..clear()
      ..addAll(previous.conversationOrder);
    currentConversation = previous.currentConversation;
    composerFraction = previous.composerFraction;
    readBaseline = previous.readBaseline;
    appearance = previous.appearance;
    language = previous.language;
    linkFavoriteDeletion = previous.linkFavoriteDeletion;
    favoritePreferences = previous.favoritePreferences;
    _previous = null;
  }
}

class LanFlowHost extends StatefulWidget {
  const LanFlowHost({super.key, required this.session, required this.location});
  final RuntimeSession session;
  final StorageLocation location;
  @override
  State<LanFlowHost> createState() => _LanFlowHostState();
}

class _LanFlowHostState extends State<LanFlowHost> {
  late RuntimeSession _session = widget.session;
  bool _changing = false;
  String _progress = '';
  String? _notice;
  int _generation = 0;
  MobileSection _initialSection = MobileSection.conversations;
  Directory? _recoveryRoot;
  RuntimeSession? _unsavedSession;
  Future<void>? _quitting;
  late final Future<void> Function() _quitHandler;

  @override
  void initState() {
    super.initState();
    _quitHandler = _prepareToQuit;
    _attach();
  }

  @override
  void dispose() {
    PlatformBridge.clearQuitHandler(_quitHandler);
    super.dispose();
  }

  void _attach() {
    PlatformBridge.setQuitHandler(_quitHandler);
    _session.inbox.relocateStorage = _relocate;
    _session.inbox.backupStorage = _backup;
    _session.inbox.restoreStorage = (archive, destination) =>
        _changeStorage(destination, false, archive: archive);
    _session.inbox.cleanupStorage = _cleanup;
  }

  Future<void> _prepareToQuit() {
    if (_quitting != null) return _quitting!;
    final task = _saveAndQuit();
    _quitting = task;
    return task.whenComplete(() => _quitting = null);
  }

  Future<void> _saveAndQuit() async {
    // A tray exit can arrive while storage is being moved or backed up. Let
    // that transaction finish before choosing which session must be saved.
    while (_changing) {
      if (!mounted) throw StateError('应用尚未准备好退出');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final previous = _session;
    final origin = previous.lan.store.directory;
    if (!mounted) throw StateError('应用尚未准备好退出');
    _beginChange();
    if (mounted) setState(() => _progress = '正在保存并退出…');
    var closed = false;
    try {
      if (_unsavedSession != null) {
        await _restorePrevious(previous, origin);
      }
      await _session.inbox.commitPendingEdits();
      await PlatformBridge.suspendShares();
      closed = true;
      await _closePreservingEdits(_session);
      // Keep input blocked until the native acknowledgement destroys the
      // engine. A new edit must not slip in after the final durable save.
    } on Object {
      if (closed) {
        _unsavedSession = _session;
        try {
          await _restorePrevious(_session, origin);
        } on Object {
          // StartupFailure retains the pending in-memory data until retry.
        }
      }
      _notice = '退出前保存未完成，编辑内容已保留。请检查磁盘空间和权限后重试退出。';
      await _finishChange(previous);
      rethrow;
    }
  }

  Future<void> _closePreservingEdits(RuntimeSession session) async {
    try {
      await session.close();
    } on Object {
      _unsavedSession = session;
      rethrow;
    }
  }

  Future<void> _relocate(
    String destination,
    bool migrate, {
    bool createIfEmpty = false,
  }) => _changeStorage(destination, migrate, createIfEmpty: createIfEmpty);

  Future<RuntimeSession> _openLike(
    RuntimeSession previous,
    Directory root, {
    RuntimeSession? recoverFrom,
  }) async {
    final session = await RuntimeSession.open(
      root,
      enableDiscovery: previous.lan.enableDiscovery,
      preferredPort: previous.lan.preferredPort,
      bindAddress: previous.lan.bindAddress,
      recoverFrom: recoverFrom,
    );
    try {
      await session.start(acceptShares: false);
      if (!session.inbox.ready || !session.lan.ready) {
        throw const FileSystemException('新位置的数据无法打开');
      }
      return session;
    } on Object {
      try {
        await session.close();
      } on Object {
        // Keep the original startup failure and release UI listeners even if
        // the unavailable disk also prevents a final save.
      } finally {
        session.dispose();
      }
      rethrow;
    }
  }

  void _beginChange({
    MobileSection initialSection = MobileSection.conversations,
  }) {
    setState(() {
      _changing = true;
      _progress = '正在完成当前写入…';
      _notice = null;
      _initialSection = initialSection;
    });
  }

  Future<void> _finishChange(RuntimeSession previous) async {
    if (mounted) {
      setState(() {
        if (!identical(previous, _session)) _generation++;
        _changing = false;
      });
      if (!identical(previous, _session)) {
        await WidgetsBinding.instance.endOfFrame;
        previous.dispose();
      }
    }
  }

  Future<void> _backup(String destination) async {
    if (_changing || !mounted) return;
    final previous = _session;
    final origin = previous.lan.store.directory;
    _beginChange();
    var closed = false;
    Object? failure;
    try {
      await previous.inbox.commitPendingEdits();
      await PlatformBridge.suspendShares();
      closed = true;
      await _closePreservingEdits(previous);
      if (mounted) setState(() => _progress = '正在创建并校验完整备份…');
      await StorageBackup.create(origin, destination);
      final saved =
          !Platform.isAndroid ||
          await PlatformBridge.exportFile(destination, p.basename(destination));
      _notice = saved ? '完整备份已保存' : '备份已取消';
    } on Object catch (error) {
      failure = error;
      _notice = '备份未完成，原数据保留。请检查目标位置的空间和权限。';
    } finally {
      try {
        if (closed) await _restorePrevious(previous, origin);
      } finally {
        await _finishChange(previous);
      }
    }
    if (failure != null) throw failure;
  }

  Future<void> _restorePrevious(RuntimeSession previous, Directory root) async {
    try {
      _session = await _openLike(previous, root, recoverFrom: _unsavedSession);
      _unsavedSession = null;
      _attach();
      _recoveryRoot = null;
    } on Object {
      // Keep the closed session's settings for retry. Never present an editable
      // stale controller when its disk cannot be reopened.
      _recoveryRoot = root;
      rethrow;
    }
    try {
      await _session.listenShares();
    } on Object {
      _notice = '数据已打开，后台接收服务暂未恢复，请重新打开应用。';
    }
  }

  Future<Map<String, dynamic>> _cleanup(bool clearTrash) async {
    if (_changing || !mounted) throw StateError('正在处理存储，请稍后重试');
    final previous = _session;
    final origin = previous.lan.store.directory;
    _beginChange(
      initialSection: clearTrash
          ? MobileSection.trash
          : MobileSection.conversations,
    );
    var closed = false;
    try {
      await previous.inbox.commitPendingEdits();
      await PlatformBridge.suspendShares();
      closed = true;
      await _closePreservingEdits(previous);
      if (mounted) {
        setState(() => _progress = clearTrash ? '正在清空回收站…' : '正在校验并清理未使用的附件…');
      }
      final result = Map<String, dynamic>.from(
        await NativeCore.run({
              'op': 'maintenance_cleanup',
              'root': origin.path,
              'clearTrash': clearTrash,
            })
            as Map,
      );
      _notice = clearTrash
          ? '已清空回收站'
          : '已释放 ${formatBytes(result['releasedBytes'] as int? ?? 0)}';
      return result;
    } on Object {
      _notice = clearTrash ? '回收站未完全清空，请检查空间和权限后重试。' : '清理未完全完成，请检查空间和权限后重试。';
      rethrow;
    } finally {
      try {
        if (closed) await _restorePrevious(previous, origin);
      } finally {
        await _finishChange(previous);
      }
    }
  }

  Future<void> _retryStorage() async {
    if (_changing || !mounted) return;
    _beginChange(initialSection: _initialSection);
    final previous = _session;
    try {
      await _restorePrevious(previous, _recoveryRoot!);
    } finally {
      await _finishChange(previous);
    }
  }

  Future<void> _changeStorage(
    String destination,
    bool migrate, {
    String? archive,
    bool createIfEmpty = false,
  }) async {
    if (_changing || !mounted) return;
    // Reserve the operation before validation yields, so double taps cannot
    // close or replace the same live session twice.
    _beginChange();
    final previous = _session;
    final origin = previous.lan.store.directory;
    final appearance = previous.inbox.appearance.value;
    final language = previous.inbox.language.value;
    final name = previous.lan.name;
    StorageMove? move;
    StorageRestore? restoration;
    RuntimeSession? next;
    var closed = false;
    var committed = false;
    var existingData = false;
    try {
      final switching = !migrate && archive == null;
      final target = await widget.location.validate(
        origin,
        destination,
        allowExisting: switching,
      );
      if (switching) {
        existingData = await StorageLocation.containsData(target);
        if (!existingData && !createIfEmpty) {
          throw const FileSystemException('新位置没有数据，请确认是否新建');
        }
      }
      if (archive != null) {
        if (mounted) setState(() => _progress = '正在解压并校验备份…');
        restoration = await StorageBackup.restore(
          archivePath: archive,
          source: origin,
          destination: target.path,
          location: widget.location,
        );
      }
      await previous.inbox.commitPendingEdits();
      await PlatformBridge.suspendShares();
      closed = true;
      await _closePreservingEdits(previous);
      if (archive == null && migrate) {
        move = await widget.location.prepare(
          source: origin,
          destination: target.path,
          migrate: migrate,
          onProgress: (completed, total) {
            if (mounted) {
              setState(
                () => _progress = total == 0
                    ? '正在校验数据…'
                    : '正在迁移并校验 ${(completed / total * 100).round()}%',
              );
            }
          },
        );
      }
      if (switching) {
        // Recheck after closing the old session. A removed disk must never be
        // recreated just because it contained data when the dialog opened.
        existingData = await StorageLocation.containsData(target);
        if (!existingData && !createIfEmpty) {
          throw const FileSystemException('新位置没有数据，请确认是否新建');
        }
      }
      if (!existingData) {
        final local = LocalStore(target);
        final localState = await local.load();
        localState['receiveDirectory'] = StorageLayout.received(target).path;
        if (!migrate && archive == null) localState['name'] = name;
        final oldRoot = restoration?.sourceRoot ?? origin.path;
        final oldPaths = p.Context(
          style: p.windows.isAbsolute(oldRoot)
              ? p.Style.windows
              : p.Style.posix,
        );
        for (final message in localState['messages'] as List? ?? []) {
          final path = message['path'];
          if (path is String && oldPaths.isWithin(oldRoot, path)) {
            message['path'] = p.joinAll([
              target.path,
              ...oldPaths.split(oldPaths.relative(path, from: oldRoot)),
            ]);
          }
        }
        await local.save(localState);
      }
      // Opening the replacement validates and loads it once. The persistent
      // location is changed only after that session has started successfully.
      next = await _openLike(previous, target);
      if (!migrate && archive == null && !existingData) {
        await next.inbox.setAppearance(appearance);
        await next.inbox.setLanguage(language);
      }
      // The next session is known to open before the persistent pointer moves.
      await widget.location.activate(target);
      _session = next;
      _attach();
      committed = true;
      var cleaned = true;
      try {
        await widget.location.confirm();
        if (restoration != null) await restoration.commit();
        if (move != null) cleaned = await move.finish();
      } on Object {
        // The main locator already points at the working session. If updating
        // its fallback or cleaning up fails, retain both data copies.
        cleaned = false;
      }
      _notice = archive != null
          ? '备份已恢复到新位置，原位置的数据保留。'
          : migrate
          ? cleaned
                ? '数据已迁移到新位置'
                : '已切换到新位置，部分旧文件仍保留在原位置'
          : existingData
          ? '已切换到所选位置的数据，原位置的数据保留。'
          : '已在新位置重新开始。原数据保留，其他设备需要重新绑定。';
      await next.listenShares();
    } on Object {
      if (committed) {
        _notice = '数据已切换到新位置，后台接收服务暂未恢复，请重新打开应用。';
        return;
      }
      if (next != null) {
        try {
          await next.close();
        } on Object {
          // Cleanup errors must not prevent reopening the original session.
        } finally {
          next.dispose();
        }
      }
      try {
        await move?.discard();
      } on Object {
        /* Preserve the extra copy. */
      }
      try {
        await restoration?.discard();
      } on Object {
        /* Preserve the extra copy. */
      }
      if (closed) {
        await _restorePrevious(previous, origin);
      }
      _notice = archive != null
          ? '备份恢复未完成，原数据保留。请检查备份文件、磁盘空间和权限后重试。'
          : '位置切换未完成，已回到原位置，原数据保留。请检查磁盘空间和权限后重试。';
    } finally {
      await _finishChange(previous);
    }
  }

  @override
  Widget build(BuildContext context) => _recoveryRoot != null
      ? AppRoot(
          language: _session.inbox.store.language,
          home: StartupFailure(onRetry: _retryStorage),
        )
      : LanFlowApp(
          key: ValueKey(_generation),
          controller: _session.lan,
          inbox: _session.inbox,
          interactionsBlocked: _changing,
          initialSection: _initialSection,
          builder: (context, child) => RuntimeFeedback(
            changing: _changing,
            progress: _progress,
            notice: _notice,
            onDismiss: () => setState(() => _notice = null),
            child: child!,
          ),
        );
}
