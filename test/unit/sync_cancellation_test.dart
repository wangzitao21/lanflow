import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/inbox/inbox_sync.dart';
import 'package:lanflow/platform/native_core.dart';

void main() {
  final endpoint = SyncEndpoint(
    id: 'peer',
    name: 'peer',
    url: Uri.parse('https://127.0.0.1'),
    fingerprint: 'f' * 64,
    token: 'token',
  );
  late InboxSync sync;
  late List<String> operations;
  late List<Completer<void>> cancellations;
  var autoRelease = false;
  setUp(() {
    autoRelease = false;
    operations = [];
    cancellations = [];
    final store = InboxStore(
      Directory('${Directory.systemTemp.path}/lanflow-cancel-order'),
    );
    sync = InboxSync(
      store,
      (_) async {},
      invoke: (request) async {
        final op = request['op'] as String;
        if (op == 'cancel_sync' && request['key'] == null) return null;
        operations.add(op);
        if (op == 'cancel_sync') {
          final gate = Completer<void>();
          cancellations.add(gate);
          if (autoRelease) gate.complete();
          await gate.future;
          return null;
        }
        if (op == 'begin_sync') return 'fresh-run';
        if (op == 'sync') {
          return {'unchanged': true, 'revision': -1, 'changeCursor': 0};
        }
        throw StateError('Unexpected operation $op');
      },
    );
  });
  tearDown(() async {
    autoRelease = true;
    for (final gate in cancellations) {
      if (!gate.isCompleted) gate.complete();
    }
    await sync.close();
  });

  test(
    'replacement waits for all earlier native cancellations on its endpoint',
    () async {
      final first = sync.cancel(endpoint.key);
      final second = sync.cancel(endpoint.key);
      final resumed = sync.sync(endpoint);
      await Future<void>.delayed(Duration.zero);
      expect(operations, ['cancel_sync']);
      cancellations.first.complete();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(operations, ['cancel_sync', 'cancel_sync']);
      cancellations.last.complete();
      await second;
      await resumed;
      expect(operations, ['cancel_sync', 'cancel_sync', 'begin_sync', 'sync']);
    },
  );

  test(
    'another network change supersedes a waiting resume without starting it',
    () async {
      final first = sync.cancel(endpoint.key);
      final staleResume = sync.sync(endpoint);
      final cancelled = expectLater(
        staleResume,
        throwsA(
          isA<NativeCoreError>().having(
            (e) => e.category,
            'category',
            'cancelled',
          ),
        ),
      );
      final second = sync.cancel(endpoint.key);
      cancellations.first.complete();
      await first;
      await cancelled;
      await Future<void>.delayed(Duration.zero);
      expect(operations, ['cancel_sync', 'cancel_sync']);
      cancellations.last.complete();
      await second;
      await sync.sync(endpoint);
      expect(operations.last, 'sync');
    },
  );
}
