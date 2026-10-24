import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/core/storage/local_store.dart';
import 'package:lanflow/core/storage/storage_layout.dart';
import 'package:lanflow/platform/native_core.dart';

// Opt-in because seeding and testing 110,000 real records is deliberately more
// expensive than the normal regression suite. Timings are host/debug timings,
// not Flutter frame times or a release-mode user-interface benchmark.
void main() {
  final enabled = Platform.environment['LANFLOW_RUN_HISTORY_BENCH'] == '1';
  final output = File(
    Platform.environment['LANFLOW_HISTORY_BENCH_OUTPUT'] ??
        'build/history-scaling.json',
  );
  final results = <Map<String, dynamic>>[];
  for (final count in [10000, 100000]) {
    test(
      'SQLite history scaling with $count messages',
      () async {
        final root = await Directory.systemTemp.createTemp('lanflow-history-');
        InboxController? controller;
        LanController? lan;
        try {
          final baselineSource = await _verifyBaseline();
          await NativeCore.run({'op': 'open', 'root': root.path});
          await NativeCore.run({'op': 'close', 'root': root.path});
          final python =
              Platform.environment['LANFLOW_BENCH_PYTHON'] ?? 'python';
          final seed = await Process.run(python, [
            'test/performance/history_fixture.py',
            root.path,
            '$count',
          ]);
          expect(seed.exitCode, 0, reason: '${seed.stderr}\n${seed.stdout}');
          final fixture =
              jsonDecode(seed.stdout as String) as Map<String, dynamic>;
          final beforePagedRss = ProcessInfo.currentRss;
          final paged = InboxStore(root);
          final pagedWatch = Stopwatch()..start();
          await paged.load();
          pagedWatch.stop();
          final afterPagedRss = ProcessInfo.currentRss;
          final pagedResident = paged.entries.length;
          expect(paged.messageCount, count);
          expect(pagedResident, lessThanOrEqualTo(200));
          final firstWindow = paged.entries
              .map((entry) => entry.item.id)
              .toSet();
          await paged.loadConversation(defaultConversationId, older: true);
          expect(paged.entries.length, lessThanOrEqualTo(400));
          expect(
            paged.entries
                .map((entry) => entry.item.id)
                .toSet()
                .containsAll(firstWindow),
            isTrue,
          );
          await paged.close();
          paged.releaseClosedHistory();
          final beforeRss = ProcessInfo.currentRss;
          final store = InboxStore(root, eagerHistory: true);
          final load = Stopwatch()..start();
          await store.load();
          load.stop();
          final afterLoadRss = ProcessInfo.currentRss;
          expect(store.entries.length, count);
          lan = LanController(
            store: LocalStore(root),
            receiveDirectory: StorageLayout.received(root),
            enableDiscovery: false,
          );
          controller = InboxController(
            lan: lan,
            store: store,
            automaticSync: false,
          );
          final firstAccess = Stopwatch()..start();
          final initialItems = controller.items;
          final initialGroup = controller.itemsIn(defaultConversationId);
          firstAccess.stop();
          expect(initialItems.length, count);
          expect(initialGroup.length, (count / 16).ceil());
          final baseline = _ArchivedIndex(store);
          final coldOld = Stopwatch()..start();
          final initialOld = baseline.items;
          coldOld.stop();
          expect(_sameOrdering(initialItems, initialOld), isTrue);

          final receiptTimes = <double>[];
          final currentAccess = <double>[];
          final archivedAccess = <double>[];
          final contentRevision = store.contentRevision;
          var readChecksum = 0;
          for (var iteration = 0; iteration < 30; iteration++) {
            final item = store.entries[(iteration * 311) % count].item;
            final receipt = Stopwatch()..start();
            await store.add(item, source: 'device:receipt-bench-$iteration');
            receipt.stop();
            receiptTimes.add(receipt.elapsedMicroseconds.toDouble());
            expect(
              store.find(item.id)!.copies,
              contains('device:receipt-bench-$iteration'),
            );
            expect(
              store.contentRevision,
              contentRevision,
              reason: 'A receipt must not invalidate message order',
            );
            final current = Stopwatch()..start();
            for (var read = 0; read < 1000; read++) {
              readChecksum +=
                  controller.items.length +
                  controller.itemsIn(defaultConversationId).length;
            }
            current.stop();
            currentAccess.add(current.elapsedMicroseconds / 1000);
            expect(identical(controller.items, initialItems), isTrue);
            expect(
              identical(
                controller.itemsIn(defaultConversationId),
                initialGroup,
              ),
              isTrue,
            );
            final archived = Stopwatch()..start();
            final oldItems = baseline.items;
            readChecksum +=
                oldItems.length +
                baseline.itemsIn(defaultConversationId).length;
            archived.stop();
            archivedAccess.add(archived.elapsedMicroseconds.toDouble());
            expect(oldItems.first.item.id, initialItems.first.item.id);
            expect(oldItems.last.item.id, initialItems.last.item.id);
          }
          expect(readChecksum, greaterThan(0));

          // The oracle is independent of SQL and is kept outside measured work.
          final expected = controller.items
              .where(
                (entry) => entry.item.text.toLowerCase().contains('needle'),
              )
              .map((entry) => entry.item.id)
              .toList();
          expect(expected.length, fixture['searchMatches']);
          final received = <String>[];
          final pageTimes = <double>[];
          final pulse = Stopwatch()..start();
          var pulses = 0;
          var lastPulse = 0;
          var maxPulseGap = 0;
          final heartbeat = Timer.periodic(const Duration(milliseconds: 2), (
            _,
          ) {
            final now = pulse.elapsedMicroseconds;
            final gap = now - lastPulse;
            if (gap > maxPulseGap) maxPulseGap = gap;
            lastPulse = now;
            pulses++;
          });
          var offset = 0;
          try {
            while (true) {
              final watch = Stopwatch()..start();
              final page = await controller.searchMessages({
                'query': 'needle',
                'offset': offset,
                'limit': 50,
              });
              watch.stop();
              pageTimes.add(watch.elapsedMicroseconds.toDouble());
              expect(page['total'], expected.length);
              final ids = List<String>.from(page['ids'] as List);
              expect(ids.length, lessThanOrEqualTo(50));
              received.addAll(ids);
              if (page['more'] != true) break;
              expect(page['nextOffset'] as int, greaterThan(offset));
              offset = page['nextOffset'] as int;
            }
          } finally {
            heartbeat.cancel();
            pulse.stop();
          }
          expect(received, orderedEquals(expected));
          expect(received.toSet().length, received.length);
          expect(
            pulses,
            greaterThan(0),
            reason:
                'Database searches must leave the main isolate able to process timers',
          );
          final filteredWatch = Stopwatch()..start();
          final filtered = await controller.searchMessages({
            'query': 'needle',
            'conversationId': defaultConversationId,
            'kind': 'text',
            'limit': 200,
          });
          filteredWatch.stop();
          final expectedFiltered = controller
              .itemsIn(defaultConversationId)
              .where((entry) => entry.item.text.contains('needle'))
              .map((entry) => entry.item.id)
              .toList();
          expect(filtered['ids'], orderedEquals(expectedFiltered));
          final shortWatch = Stopwatch()..start();
          final short = await controller.searchMessages({
            'query': '说明',
            'limit': 50,
          });
          shortWatch.stop();
          expect(short['total'], count);
          expect((short['ids'] as List).length, 50);
          final frequentWatch = Stopwatch()..start();
          final frequent = await controller.searchMessages({
            'query': 'payload',
            'limit': 50,
          });
          frequentWatch.stop();
          expect(frequent['total'], count);
          expect((frequent['ids'] as List).length, 50);

          final targets = controller.items
              .take(count ~/ 10)
              .map((entry) => entry.item.id)
              .toList();
          final removed = targets.toSet();
          final untouched = controller.items.firstWhere(
            (entry) => !removed.contains(entry.item.id),
          );
          final delete = Stopwatch()..start();
          await controller.deleteItems(targets);
          delete.stop();
          expect(controller.items.length, count - targets.length);
          expect(
            controller.items.any((entry) => removed.contains(entry.item.id)),
            isFalse,
          );
          expect(
            store.conversationEntries.values
                .expand((entries) => entries)
                .length,
            count - targets.length,
          );
          expect(identical(store.find(untouched.item.id), untouched), isTrue);
          final trash = await store.deletedPage();
          expect(trash['total'], targets.length);
          expect((trash['items'] as List).length, 50);
          final afterDelete = await store.searchMessages({
            'query': 'needle',
            'limit': 200,
          });
          expect(
            afterDelete['total'],
            expected.where((id) => !removed.contains(id)).length,
          );
          final reopen = Stopwatch()..start();
          await store.close();
          final reopened = InboxStore(root, eagerHistory: true);
          await reopened.load();
          reopen.stop();
          expect(reopened.entries.length, count - targets.length);
          expect(reopened.deleted.containsAll(targets), isTrue);
          await reopened.close();

          final result = <String, dynamic>{
            'messages': count,
            'conversations': 16,
            'fixture': fixture,
            'baseline': baselineSource,
            'initialStoreLoadMs': load.elapsedMicroseconds / 1000,
            'pagedStoreLoadMs': pagedWatch.elapsedMicroseconds / 1000,
            'pagedResidentRecords': pagedResident,
            'pagedRssIncreaseBytes': afterPagedRss - beforePagedRss,
            'firstIndexedItemsAccessMs': firstAccess.elapsedMicroseconds / 1000,
            'firstArchivedSortAndGroupMs': coldOld.elapsedMicroseconds / 1000,
            'receiptUpdateMs': _statsMs(receiptTimes),
            'indexedAccessAfterReceiptMs': _statsMs(currentAccess),
            'archivedSortAndGroupAfterReceiptMs': _statsMs(archivedAccess),
            'searchPages': pageTimes.length,
            'searchMatches': expected.length,
            'searchPageMs': _statsMs(pageTimes),
            'filteredSearchMs': filteredWatch.elapsedMicroseconds / 1000,
            'shortChineseSearchMs': shortWatch.elapsedMicroseconds / 1000,
            'frequentTermSearchMs': frequentWatch.elapsedMicroseconds / 1000,
            'searchMainIsolateTimerPulses': pulses,
            'maxSearchMainIsolateTimerGapMs': maxPulseGap / 1000,
            'bulkDeleted': targets.length,
            'bulkDeleteMs': delete.elapsedMicroseconds / 1000,
            'reopenAfterDeleteMs': reopen.elapsedMicroseconds / 1000,
            'rssBeforeLoadBytes': beforeRss,
            'rssAfterLoadBytes': afterLoadRss,
            'mode':
                'Flutter test/debug; release native DLL; OS caches not cleared; not a frame-rate measurement',
          };
          results.add(result);
          await output.parent.create(recursive: true);
          await output.writeAsString(
            const JsonEncoder.withIndent('  ').convert({'results': results}),
          );
          // A machine-readable single line is easier to compare across runs.
          // ignore: avoid_print
          print('HISTORY_BENCH ${jsonEncode(result)}');
        } finally {
          await controller?.close();
          controller?.dispose();
          await lan?.close();
          lan?.dispose();
          await NativeCore.run({'op': 'close', 'root': root.path});
          await root.delete(recursive: true);
        }
      },
      skip: enabled
          ? false
          : 'Set LANFLOW_RUN_HISTORY_BENCH=1 and LANFLOW_BENCH_PYTHON for the opt-in large-history benchmark',
      timeout: const Timeout(Duration(minutes: 8)),
    );
  }
}

Map<String, num> _statsMs(List<double> micros) {
  final sorted = micros.toList()..sort();
  return {
    'count': sorted.length,
    'median': sorted[sorted.length ~/ 2] / 1000,
    'p95': sorted[((sorted.length - 1) * .95).round()] / 1000,
    'max': sorted.last / 1000,
  };
}

bool _sameOrdering(List<InboxEntry> left, List<InboxEntry> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index].item.id != right[index].item.id) return false;
  }
  return true;
}

Future<Map<String, dynamic>> _verifyBaseline() async {
  final path = File('build/optimization-before.zip');
  if (!await path.exists()) {
    return {
      'source': 'archived getter copied into test',
      'archiveVerified': false,
    };
  }
  final archive = ZipDecoder().decodeBytes(await path.readAsBytes());
  final entry = archive.files.firstWhere(
    (entry) => entry.name
        .replaceAll('\\', '/')
        .endsWith('lib/core/inbox/inbox_controller.dart'),
  );
  final source = utf8
      .decode(entry.content as List<int>)
      .replaceAll('\r\n', '\n');
  final start = source.indexOf('  List<InboxEntry> get items {');
  final end = source.indexOf('  List<Conversation> get conversations', start);
  final getter = source.substring(start, end);
  expect(
    getter,
    contains('if (_sortedRevision == store.revision) return _sortedItems;'),
  );
  expect(getter, contains('_sortedItems = store.entries.toList()'));
  expect(
    getter,
    contains('final time = b.item.createdAt.compareTo(a.item.createdAt);'),
  );
  expect(
    getter,
    contains('(_groupedItems[item.item.conversationId] ??= []).add(item);'),
  );
  return {
    'source':
        'build/optimization-before.zip:lib/core/inbox/inbox_controller.dart',
    'archiveVerified': true,
    'getterSha256': sha256.convert(utf8.encode(getter)).toString(),
  };
}

// Getter and invalidation logic copied from the verified pre-change archive.
class _ArchivedIndex {
  _ArchivedIndex(this.store);
  final InboxStore store;
  int _sortedRevision = -2;
  List<InboxEntry> _sortedItems = [];
  Map<String, List<InboxEntry>> _groupedItems = {};
  List<InboxEntry> get items {
    if (_sortedRevision == store.revision) return _sortedItems;
    _sortedRevision = store.revision;
    _sortedItems = store.entries.toList()
      ..sort((a, b) {
        final time = b.item.createdAt.compareTo(a.item.createdAt);
        return time == 0 ? b.item.id.compareTo(a.item.id) : time;
      });
    _groupedItems = {};
    for (final item in _sortedItems) {
      (_groupedItems[item.item.conversationId] ??= []).add(item);
    }
    return _sortedItems;
  }

  List<InboxEntry> itemsIn(String id) {
    items;
    return _groupedItems[id] ?? const [];
  }
}
