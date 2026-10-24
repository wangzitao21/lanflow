import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/platform/share_import_progress.dart';
import 'package:lanflow/ui/shared/app_root.dart';
import 'package:lanflow/ui/shared/share_import_notice.dart';

void main() {
  test('late copy events cannot revive cancelled or committed shares', () {
    final tracker = ShareImportTracker();
    addTearDown(tracker.dispose);
    final snapshot = tracker.beginSnapshot();
    tracker.update(const ShareImportProgress(id: 'first'));
    tracker.update(const ShareImportProgress(id: 'first', phase: 'saving'));
    tracker.update(const ShareImportProgress(id: 'first', phase: 'ready'));
    expect(tracker.value.single.phase, 'saving');
    tracker.update(const ShareImportProgress(id: 'first', phase: 'completed'));
    expect(snapshot, contains('first'));
    tracker.update(const ShareImportProgress(id: 'first'));
    expect(tracker.value, isEmpty);
    tracker.update(const ShareImportProgress(id: 'second', phase: 'cancelled'));
    tracker.update(const ShareImportProgress(id: 'second', phase: 'copying'));
    expect(tracker.value, isEmpty);
    tracker.endSnapshot(snapshot);
  });

  test(
    'failed durable saves remain retryable and progress preserves queue order',
    () {
      final tracker = ShareImportTracker();
      addTearDown(tracker.dispose);
      tracker.update(const ShareImportProgress(id: 'first'));
      tracker.update(const ShareImportProgress(id: 'second', phase: 'queued'));
      tracker.update(const ShareImportProgress(id: 'first', bytes: 100));
      expect(tracker.value.map((item) => item.id), ['first', 'second']);
      tracker.update(const ShareImportProgress(id: 'first', phase: 'failed'));
      tracker.update(const ShareImportProgress(id: 'first', phase: 'saving'));
      expect(tracker.value.last.phase, 'saving');
    },
  );

  test('share progress tolerates unknown sizes and clamps byte fractions', () {
    final unknown = ShareImportProgress.fromJson({
      'id': 'share-1',
      'bytes': 500,
      'totalBytes': -1,
    });
    expect(unknown.fraction, isNull);
    expect(unknown.totalBytes, 0);
    final copying = ShareImportProgress.fromJson({
      'id': 'share-1',
      'bytes': 501,
      'totalBytes': 500,
    });
    expect(copying.fraction, 1);
    expect(copying.canCancel, isTrue);
    expect(
      const ShareImportProgress(id: 'share-1', phase: 'saving').canCancel,
      isFalse,
    );
  });

  testWidgets(
    'large-text progress shows bytes, cancels once and protects saving',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final progress = ValueNotifier<List<ShareImportProgress>>([
        const ShareImportProgress(
          id: 'share-1',
          name: 'large-file.zip',
          fileIndex: 1,
          fileCount: 2,
          bytes: 1024,
          totalBytes: 2048,
        ),
      ]);
      addTearDown(progress.dispose);
      var cancels = 0;
      final gate = Completer<bool>();
      await tester.pumpWidget(
        AppRoot(
          language: 'en',
          home: Scaffold(
            body: Column(
              children: [
                ShareImportNotice(
                  progress: progress,
                  onCancel: (id) {
                    expect(id, 'share-1');
                    cancels++;
                    return gate.future;
                  },
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Importing shared files…'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .5,
      );
      await tester.tap(find.byKey(const ValueKey('cancel-share-share-1')));
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('cancel-share-share-1')),
            )
            .onPressed,
        isNull,
      );
      expect(cancels, 1);
      gate.complete(false);
      await tester.pump();
      progress.value = [
        const ShareImportProgress(id: 'share-1', phase: 'saving'),
      ];
      await tester.pump();
      expect(find.text('Saving shared content…'), findsOneWidget);
      expect(find.byKey(const ValueKey('cancel-share-share-1')), findsNothing);
      progress.value = [];
      await tester.pump();
      expect(find.byKey(const ValueKey('share-import-notice')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
