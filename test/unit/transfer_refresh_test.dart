import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/core/storage/local_store.dart';

class _TransferReadStore extends InboxStore {
  _TransferReadStore(super.directory);
  final reads = <Completer<List<Map<String, dynamic>>>>[];
  @override
  Future<List<Map<String, dynamic>>> transfers() {
    final read = Completer<List<Map<String, dynamic>>>();
    reads.add(read);
    return read.future;
  }
}

void main() {
  late _TransferReadStore store;
  late LanController lan;
  late InboxController inbox;
  setUp(() {
    final root = Directory(
      '${Directory.systemTemp.path}/lanflow-transfer-read-unit',
    );
    store = _TransferReadStore(root);
    lan = LanController(store: LocalStore(root), receiveDirectory: root);
    lan.sessions['b' * 32] = PeerSession(
      receiveToken: 'receive',
      sendToken: 'send',
    );
    inbox = InboxController(lan: lan, store: store, automaticSync: false)
      ..ready = true;
  });
  tearDown(() {
    inbox.dispose();
    lan.dispose();
  });
  Map<String, dynamic> task(String id) => {
    'endpoint': 'device:${'b' * 32}',
    'direction': 'upload',
    'eventId': id,
    'state': 'failed',
    'transferred': 0,
    'item': {
      'id': id,
      'originId': 'a' * 32,
      'originName': 'Sender',
      'createdAt': '2026-10-22T00:00:00Z',
      'kind': 'file',
      'name': '$id.bin',
      'size': 4,
      'sha256': 'c' * 64,
    },
  };

  test('a refresh requested during a read waits for a fresh snapshot', () async {
    final first = inbox.refreshTransfers();
    var completed = false;
    final afterCommit = inbox.refreshTransfers().then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(
      completed,
      isFalse,
      reason:
          'An overlapping awaited refresh cannot report completion before its read',
    );
    store.reads.first.complete([
      task('waiting-attachment'),
      task('healthy-attachment'),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(
      store.reads.length,
      2,
      reason: 'The old in-flight snapshot predates the completed transfer',
    );
    expect(completed, isFalse);
    store.reads.last.complete([task('waiting-attachment')]);
    await Future.wait([first, afterCommit]);
    expect(inbox.transferTasks.single.item.id, 'waiting-attachment');
  });

  test(
    'a failed coalesced refresh stops and can be retried explicitly',
    () async {
      final first = inbox.refreshTransfers();
      final concurrent = inbox.refreshTransfers();
      final firstError = expectLater(first, throwsStateError);
      final concurrentError = expectLater(concurrent, throwsStateError);
      store.reads.first.completeError(StateError('temporary read failure'));
      await Future.wait([firstError, concurrentError]);
      await Future<void>.delayed(Duration.zero);
      expect(
        store.reads.length,
        1,
        reason: 'A read failure must not recursively requeue itself',
      );
      final retry = inbox.refreshTransfers();
      store.reads.last.complete([]);
      await retry;
      expect(store.reads.length, 2);
    },
  );

  testWidgets(
    'slow progress reads are not perpetually extended by polling ticks',
    (tester) async {
      lan.ready = true;
      var finished = false;
      final syncing = inbox.syncNow().then((_) => finished = true);
      expect(store.reads.length, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(store.reads.length, 1);
      store.reads.single.complete([]);
      await tester.pump();
      expect(
        finished,
        isTrue,
        reason:
            'Periodic sampling must not queue another read behind every slow snapshot',
      );
      await syncing;
      await tester.pump(const Duration(seconds: 2));
      expect(
        store.reads.length,
        1,
        reason: 'The completed sync cancels its sampling timer',
      );
    },
  );
}
