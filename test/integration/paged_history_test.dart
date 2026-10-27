import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/models.dart';

void main() {
  test(
    'large history stays paged without losing old search, quotes, unread counts or deletion',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-paged-history-',
      );
      InboxStore? active;
      try {
        final seed = InboxStore(root);
        active = seed;
        await seed.load();
        final expected = <InboxItem>[];
        for (var i = 0; i < 1205; i++) {
          final item = InboxItem(
            id: 'paged-message-${i.toString().padLeft(8, '0')}',
            originId: i.isEven ? 'paged-origin-self' : 'paged-origin-peer',
            originName: 'History test',
            createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: i ~/ 3)),
            kind: MessageKind.text,
            text: '说明消息 $i',
            conversationId: defaultConversationId,
          );
          expected.add(item);
          await seed.add(item);
        }
        await seed.setFavorites([expected[17].id], true);
        seed.readBaseline = 0;
        await seed.close();
        final store = InboxStore(root);
        active = store;
        await store.load();
        expect(store.pagedHistory, isTrue);
        expect(store.messageCount, 1205);
        expect(store.entries.length, 200);
        expect(
          store.latestIn(defaultConversationId)!.item.id,
          expected.last.id,
        );
        expect(store.originalExists(store.favoriteEntries.single), isTrue);
        expect(
          await store.countUnread(
            defaultConversationId,
            0,
            'paged-origin-self',
          ),
          602,
        );
        final initial = store.conversationEntries[defaultConversationId]!
            .map((e) => e.item.id)
            .toList();
        expect(initial, expected.reversed.take(200).map((e) => e.id));
        final search = await store.searchMessages({
          'query': '说明消息 17',
          'limit': 100,
        });
        expect(search['ids'], contains(expected[17].id));
        expect(store.find(expected[17].id)?.item.text, '说明消息 17');
        await store.loadContext(expected[500].id);
        expect(store.contextEntries.length, 201);
        expect(
          store.contextEntries.any(
            (entry) => entry.item.id == expected[500].id,
          ),
          isTrue,
        );
        await store.extendContext(newer: false);
        expect(store.contextEntries.length, 401);
        await store.loadConversation(defaultConversationId, older: true);
        expect(store.conversationEntries[defaultConversationId]!.length, 400);
        expect(
          store.conversationEntries[defaultConversationId]!
              .map((e) => e.item.id)
              .toSet()
              .length,
          400,
        );
        await store.remove(expected[500].id);
        expect(
          store.contextEntries.any(
            (entry) => entry.item.id == expected[500].id,
          ),
          isFalse,
        );
        expect(store.messageCount, 1204);
        expect(await store.loadEntry(expected[500].id), isNull);
        final all = await store.conversationIds(defaultConversationId);
        expect(all.length, 1204);
        expect((await store.loadEntries(all)).length, 1204);
        await store.removeConversation(defaultConversationId);
        expect(store.messageCount, 0);
        expect(await store.conversationIds(defaultConversationId), isEmpty);
        expect(store.favoriteEntries, isEmpty);
        expect((await store.deletedPage())['total'], 1205);
        await store.close();
        final reopened = InboxStore(root);
        active = reopened;
        await reopened.load();
        expect(reopened.entries, isEmpty);
        expect(reopened.favoriteEntries, isEmpty);
      } finally {
        await active?.close();
        final boundary = await Directory.systemTemp.resolveSymbolicLinks();
        final resolved = await root.resolveSymbolicLinks();
        expect(
          resolved.startsWith(
            '$boundary${Platform.pathSeparator}lanflow-paged-history-',
          ),
          isTrue,
        );
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
