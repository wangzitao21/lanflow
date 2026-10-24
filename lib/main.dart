import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'core/storage/storage_location.dart';
import 'runtime.dart';
import 'platform/platform_bridge.dart';
import 'ui/shared/app_root.dart';
import 'ui/shared/runtime_feedback.dart';

Future<void> main() => launchLanFlow();

typedef StartupSessionOpener =
    Future<RuntimeSession> Function(
      Directory root, {
      Directory? receiveDirectory,
      RuntimeSession? recoverFrom,
    });

Future<void> launchLanFlow({
  Future<Directory> Function()? resolveBootstrap,
  StartupSessionOpener? openSession,
  Future<void> Function(RuntimeSession)? startSession,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final override = Platform.environment['LANFLOW_DATA_DIR'];
  Future<void>? launching;
  RuntimeSession? openingSession;
  RuntimeSession? recoverySession;
  final retired = <RuntimeSession>{};
  var quitting = false;
  void retireAfterFrame() {
    final pending = retired.toList();
    retired.clear();
    if (pending.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final session in pending) {
        session.dispose();
      }
    });
  }

  late final Future<void> Function() startupQuit;
  startupQuit = () async {
    quitting = true;
    try {
      // Register this fallback before the first directory lookup can fail.
      // Wait for an in-flight retry before deciding which session owns edits.
      await launching;
      if (!await PlatformBridge.prepareToQuit(excluding: startupQuit)) {
        if (recoverySession != null) {
          throw StateError('退出前保存未完成，请先重试打开存储位置');
        }
        try {
          await openingSession?.close();
        } on Object {
          if (openingSession?.isClosed == true) {
            recoverySession = openingSession;
          }
          rethrow;
        }
      }
    } on Object {
      quitting = false;
      rethrow;
    }
  };
  PlatformBridge.setQuitHandler(startupQuit, fallback: true);

  Future<void> launch() async {
    if (quitting) throw StateError('应用正在退出');
    try {
      final previous = openingSession;
      if (previous != null && !identical(previous, recoverySession)) {
        try {
          await previous.close();
          retired.add(previous);
        } on Object {
          if (!previous.isClosed) rethrow;
          // close() disables controllers before saving. Retain their edits;
          // a second idempotent close is not proof that the save succeeded.
          if (recoverySession == null ||
              (previous.inbox.ready && previous.lan.ready)) {
            final superseded = recoverySession;
            recoverySession = previous;
            if (superseded != null) retired.add(superseded);
          } else {
            retired.add(previous);
          }
        }
        openingSession = recoverySession;
      }
      final bootstrap = resolveBootstrap != null
          ? await resolveBootstrap()
          : override == null
          ? await getApplicationSupportDirectory()
          : Directory(override);
      final location = StorageLocation(bootstrap);
      final root = await location.resolve();
      if (recoverySession != null &&
          !p.equals(root.path, recoverySession!.lan.store.directory.path)) {
        throw const FileSystemException('请先恢复原存储位置以保留未保存的内容');
      }
      Directory? received;
      if (p.equals(root.path, bootstrap.path)) {
        final downloads = override != null
            ? Directory(p.join(override, 'downloads'))
            : Platform.isAndroid
            ? await getApplicationDocumentsDirectory()
            : await getDownloadsDirectory() ??
                  await getApplicationDocumentsDirectory();
        received = Directory(p.join(downloads.path, 'LanFlow'));
      }
      final session = await (openSession ?? RuntimeSession.open)(
        root,
        receiveDirectory: received,
        recoverFrom: recoverySession,
      );
      openingSession = session;
      runApp(LanFlowHost(session: session, location: location));
      await (startSession?.call(session) ?? session.start());
      if (recoverySession != null) {
        if (!session.inbox.ready || !session.lan.ready) {
          throw const FileSystemException('存储启动未完成');
        }
        retired.add(recoverySession!);
        recoverySession = null;
      }
    } on Object {
      runApp(
        AppRoot(
          language: openingSession?.inbox.language.value ?? 'zh',
          home: StartupFailure(onRetry: () => launching = launch()),
        ),
      );
    } finally {
      retireAfterFrame();
    }
  }

  launching = launch();
  await launching;
}
