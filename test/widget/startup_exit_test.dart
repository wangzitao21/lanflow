import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/storage/storage_location.dart';
import 'package:lanflow/main.dart';
import 'package:lanflow/platform/platform_bridge.dart';
import 'package:lanflow/runtime.dart';
import 'package:lanflow/ui/shared/runtime_feedback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lanflow/desktop'),
          (_) async => null,
        );
  });
  tearDown(() {
    PlatformBridge.setQuitHandler(() async {}, fallback: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('lanflow/desktop'), null);
  });

  testWidgets(
    'support directory failure still renders retry and permits a safe native exit',
    (tester) async {
      await tester.runAsync(
        () => launchLanFlow(
          resolveBootstrap: () => Future<Directory>.error(
            const FileSystemException('support directory unavailable'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(StartupFailure), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(
        await tester.runAsync(() => PlatformBridge.prepareToQuit()),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !Platform.isWindows,
  );

  for (final failClose in [false, true]) {
    testWidgets(
      'startup retry releases the old listener and preserves edits (close failure: $failClose)',
      (tester) async {
        final sessions = <RuntimeSession>[];
        late Directory temporary;
        var oldListenerClosed = false;
        int? previousPort;
        Directory? blockedWrite;
        try {
          await tester.runAsync(() async {
            temporary = await Directory.systemTemp.createTemp(
              'lanflow-startup-retry-',
            );
            final bootstrap = await Directory(
              '${temporary.path}/bootstrap',
            ).create();
            final data = await Directory('${temporary.path}/data').create();
            await StorageLocation(bootstrap).activate(data);
            await launchLanFlow(
              resolveBootstrap: () async => bootstrap,
              openSession: (root, {receiveDirectory, recoverFrom}) async {
                if (sessions.isNotEmpty) {
                  expect(recoverFrom != null, failClose);
                  if (blockedWrite != null) await blockedWrite!.delete();
                  try {
                    final socket = await Socket.connect(
                      InternetAddress.loopbackIPv4,
                      previousPort!,
                      timeout: const Duration(seconds: 1),
                    );
                    socket.destroy();
                  } on SocketException {
                    oldListenerClosed = true;
                  }
                }
                final session = await RuntimeSession.open(
                  root,
                  receiveDirectory: receiveDirectory,
                  recoverFrom: recoverFrom,
                  enableDiscovery: false,
                  preferredPort: 0,
                  bindAddress: InternetAddress.loopbackIPv4,
                );
                sessions.add(session);
                return session;
              },
              startSession: (session) async {
                await session.start();
                if (sessions.length == 1) {
                  previousPort = session.lan.self.port;
                  await session.lan.retrySave();
                  session.inbox.setDraft('Pending startup draft');
                  session.lan.updateSettings(
                    deviceName: 'Pending startup name',
                  );
                  session.lan.setReceivingPaused(true);
                  if (failClose) {
                    blockedWrite = Directory(
                      '${session.lan.store.deviceDirectory.path}/state.pending.json',
                    );
                    await blockedWrite!.create();
                  }
                  throw StateError('injected late startup failure');
                }
              },
            );
          });
          await tester.pumpAndSettle();
          expect(find.byType(StartupFailure), findsOneWidget);
          await tester.runAsync(
            tester.widget<StartupFailure>(find.byType(StartupFailure)).onRetry,
          );
          await tester.pumpAndSettle();
          expect(sessions, hasLength(2));
          expect(oldListenerClosed, isTrue);
          expect(sessions.last.inbox.ready, isTrue);
          expect(sessions.last.inbox.store.draft, 'Pending startup draft');
          expect(sessions.last.lan.name, 'Pending startup name');
          expect(sessions.last.lan.receivingPaused, isTrue);
          expect(find.byType(StartupFailure), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            for (final session in sessions) {
              await session.close();
            }
            if (sessions.length > 1) sessions.last.dispose();
            await temporary.delete(recursive: true);
          });
        }
      },
    );
  }
}
