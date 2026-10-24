import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import '../support/test_device.dart';

void main() {
  test(
    'network recovery wakes background synchronization without waiting for backoff',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-network-resume-',
      );
      final a = await TestDevice.create(
        '${root.path}/a',
        '电脑',
        automaticSync: true,
      );
      final b = await TestDevice.create(
        '${root.path}/b',
        '手机',
        automaticSync: true,
      );
      try {
        b.lan.onPrompt = (_) async => true;
        final peer = await a.lan.addAddress('127.0.0.1:${b.lan.self.port}');
        await a.lan.connect(peer);
        await a.inbox.syncNow();
        a.inbox.setForeground(false);
        a.inbox.setNetworkAvailable(false);
        b.inbox.setNetworkAvailable(false);
        final item = (await a.inbox.addText('离线排队的消息'))!;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(b.inbox.store.find(item.item.id), isNull);
        b.inbox.setNetworkAvailable(true);
        a.inbox.setNetworkAvailable(true);
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (b.inbox.store.find(item.item.id) == null &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(b.inbox.store.find(item.item.id), isNotNull);
      } finally {
        await a.close();
        await b.close();
        a.inbox.dispose();
        a.lan.dispose();
        b.inbox.dispose();
        b.lan.dispose();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'quotes sync, survive source deletion, and drafts and avatars survive reopening',
    () async {
      final root = await Directory.systemTemp.createTemp('lanflow-quotes-');
      final a = await TestDevice.create('${root.path}/a', '电脑');
      final b = await TestDevice.create('${root.path}/b', '手机');
      try {
        b.lan.onPrompt = (_) async => true;
        final peer = await a.lan.addAddress('127.0.0.1:${b.lan.self.port}');
        await a.lan.connect(peer);
        final original = (await a.inbox.addText('引用原文'))!;
        final quote = MessageQuote.fromItem(original.item);
        final reply = (await a.inbox.addText('我的回复', quote: quote))!;
        await a.inbox.syncNow();
        expect(
          b.inbox.store.find(reply.item.id)!.item.quote!.toJson(),
          quote.toJson(),
        );
        await a.inbox.deleteItem(original.item);
        await a.inbox.syncNow();
        expect(b.inbox.store.find(original.item.id), isNull);
        expect(b.inbox.store.find(reply.item.id)!.item.quote!.text, '引用原文');
        await a.inbox.setDraftQuote(quote);
        await a.inbox.setConversationAvatar(defaultConversationId, 'idea');
        await a.close();
        final reopened = InboxStore(Directory('${root.path}/a'));
        await reopened.load();
        expect(reopened.draftQuotes[defaultConversationId]!.text, '引用原文');
        expect(reopened.preference(defaultConversationId).avatar, 'idea');
        await reopened.close();
      } finally {
        await a.close();
        await b.close();
        a.inbox.dispose();
        a.lan.dispose();
        b.inbox.dispose();
        b.lan.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'shared content and comment reach chosen conversation without duplicates on retry',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-share-target-',
      );
      final device = await TestDevice.create(root.path, '手机');
      try {
        final target = await device.inbox.createConversation('阅读');
        final payload = {
          'id': 'share-id',
          'conversationId': target.id,
          'text': '网址',
          'comment': '稍后阅读',
          'files': [],
        };
        await device.inbox.addShared(payload);
        await device.inbox.addShared(payload);
        expect(
          device.inbox.itemsIn(target.id).map((e) => e.item.text),
          containsAll(['网址', '稍后阅读']),
        );
        expect(device.inbox.itemsIn(target.id), hasLength(2));
        expect(device.inbox.itemsIn(defaultConversationId), isEmpty);
      } finally {
        await device.close();
        device.inbox.dispose();
        device.lan.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
