import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/core/storage/local_store.dart';
import 'package:lanflow/ui/settings/recently_deleted_panel.dart';
import 'package:lanflow/ui/shared/app_root.dart';

class _TrashStore extends InboxStore {
  _TrashStore() : super(Directory('unused-recycle-bin-fixture')) {
    revision = 1;
  }

  final rows = List.generate(125, (index) => _record(index));
  int reads = 0;
  Completer<void>? gate;

  static Map<String, dynamic> _record(int index) => {
    'id': 'trash-test-item-$index',
    'source': index.isEven ? 'conversation' : 'favorite',
    'deletedAt': '2026-10-22T12:00:00Z',
    'available': true,
    'item': {
      'id': 'trash-test-item-$index',
      'originId': 'trash-test-device-001',
      'originName': 'Desktop',
      'createdAt': '2026-10-22T10:00:00Z',
      'kind': 'text',
      'text': 'Deleted message $index',
      'name': '',
      'size': 0,
      'sha256': '',
    },
  };

  @override
  Future<Map<String, dynamic>> deletedPage({
    Map<String, dynamic>? after,
    String query = '',
  }) async {
    reads++;
    final matches = rows
        .where((row) => (row['item'] as Map)['text'].contains(query))
        .toList();
    final offset = after?['offset'] as int? ?? 0;
    final entries = matches.skip(offset).take(50).toList();
    await gate?.future;
    final next = offset + entries.length;
    return {
      'items': entries,
      'total': matches.length,
      'more': next < matches.length,
      'cursor': {'offset': next},
    };
  }
}

class _TrashInbox extends InboxController {
  _TrashInbox(_TrashStore store)
    : super(
        store: store,
        lan: LanController(
          store: LocalStore(Directory('unused-recycle-bin-fixture')),
          receiveDirectory: Directory('unused-recycle-bin-fixture'),
          enableDiscovery: false,
        ),
        automaticSync: false,
      );

  void publish({bool changed = false}) {
    if (changed) store.revision++;
    notifyListeners();
  }
}

void main() {
  late _TrashStore store;
  late _TrashInbox inbox;
  late ValueNotifier<bool> active;

  setUp(() {
    store = _TrashStore();
    inbox = _TrashInbox(store);
    active = ValueNotifier(true);
  });
  tearDown(() {
    active.dispose();
    inbox.dispose();
    inbox.lan.dispose();
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      AppRoot(
        language: 'en',
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (_, enabled, _) => RecentlyDeletedPanel(
              inbox: inbox,
              embedded: true,
              active: enabled,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('retained inactive bin does no reads and refreshes on reentry', (
    tester,
  ) async {
    active.value = false;
    await mount(tester);
    expect(store.reads, 0);
    inbox.publish(changed: true);
    await tester.pump();
    expect(store.reads, 0);
    active.value = true;
    await tester.pumpAndSettle();
    expect(store.reads, 1);
    inbox.publish(); // Selection/focus notifications have no storage revision.
    await tester.pumpAndSettle();
    expect(store.reads, 1);
    active.value = false;
    await tester.pump();
    inbox.publish(changed: true);
    inbox.publish(changed: true);
    await tester.pump();
    expect(store.reads, 1);
    active.value = true;
    await tester.pumpAndSettle();
    expect(store.reads, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('refresh retains loaded pages and current scroll position', (
    tester,
  ) async {
    await mount(tester);
    final list = find.byKey(const ValueKey('trash-list'));
    final scroll = tester.widget<ListView>(list).controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('trash-load-more')));
    await tester.pumpAndSettle();
    expect(store.reads, 2);
    scroll.jumpTo(scroll.position.maxScrollExtent - 200);
    await tester.pumpAndSettle();
    final previousOffset = scroll.offset;
    expect(find.text('Deleted message 96'), findsOneWidget);

    inbox.publish(changed: true);
    await tester.pumpAndSettle();
    expect(store.reads, 4); // Both pages are refreshed, not dropped to page 1.
    expect(scroll.offset, previousOffset);
    expect(find.text('Deleted message 96'), findsOneWidget);

    active.value = false;
    await tester.pump();
    active.value = true;
    await tester.pumpAndSettle();
    expect(store.reads, 6);
    expect(scroll.offset, previousOffset);
    expect(find.text('Deleted message 96'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a change during an in-flight refresh is coalesced without loss',
    (tester) async {
      await mount(tester);
      store.gate = Completer<void>();
      inbox.publish(changed: true);
      await tester.pump();
      expect(store.reads, 2);
      store.rows.insert(0, _TrashStore._record(999));
      inbox.publish(changed: true);
      inbox.publish();
      await tester.pump();
      expect(store.reads, 2);
      store.gate!.complete();
      store.gate = null;
      await tester.pumpAndSettle();
      expect(store.reads, 3);
      expect(find.text('Deleted message 999'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'empty bin clears every page even when a search matches nothing',
    (tester) async {
      final calls = <bool>[];
      inbox.cleanupStorage = (clearTrash) async {
        calls.add(clearTrash);
        final count = store.rows.length;
        store.rows.clear();
        store.revision++;
        return {'clearedTrash': count, 'releasedBytes': 0};
      };
      await mount(tester);
      await tester.enterText(
        find.byKey(const ValueKey('trash-search')),
        'nothing matches this search',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trash-list')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('empty-local-trash')));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(
        find.textContaining('Other devices’ recycle bins are unaffected.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Empty permanently'));
      await tester.pumpAndSettle();
      expect(calls, [true]);
      expect(store.rows, isEmpty);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('trash-search')))
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('empty-local-trash')))
            .onPressed,
        isNull,
      );
      expect(find.byKey(const ValueKey('empty-trash-progress')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('trash-search')),
        'search in the empty bin',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('empty-local-trash')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'cancelling empty confirmation catches up with newly synced recycle entries',
    (tester) async {
      var cleared = false;
      inbox.cleanupStorage = (_) async {
        cleared = true;
        return {};
      };
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('empty-local-trash')));
      await tester.pumpAndSettle();
      store.rows.insert(0, _TrashStore._record(999));
      inbox.publish(changed: true);
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(cleared, isFalse);
      expect(find.text('Deleted message 999'), findsOneWidget);
      expect(store.rows, hasLength(126));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'cleanup failure keeps records and releases its navigation guard',
    (tester) async {
      final gate = Completer<Map<String, dynamic>>();
      var calls = 0;
      inbox.cleanupStorage = (_) {
        calls++;
        return gate.future;
      };
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('empty-local-trash')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Empty permanently'));
      await tester.pump();
      expect(calls, 1);
      final progress = find.byKey(const ValueKey('empty-trash-progress'));
      expect(progress, findsOneWidget);
      await Navigator.of(tester.element(progress)).maybePop();
      await tester.pump();
      expect(progress, findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('trash-search')))
            .enabled,
        isFalse,
      );
      gate.completeError(
        const FileSystemException('/private/internal/database'),
      );
      await tester.pumpAndSettle();
      expect(progress, findsNothing);
      expect(
        find.text('Cannot access files. Check storage space and permissions.'),
        findsOneWidget,
      );
      expect(find.textContaining('/private/internal'), findsNothing);
      expect(store.rows.length, 125);
      expect(find.text('Deleted message 0'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('empty-local-trash')))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
