import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';

import '../support/test_device.dart';

void main() {
  late Directory root;
  final devices = <TestDevice>[];
  Future<TestDevice> create(String name) async {
    final device = await TestDevice.create('${root.path}/$name', name);
    devices.add(device);
    return device;
  }

  Future<TestDevice> restart(TestDevice device, String name) async {
    await device.close();
    device.inbox.dispose();
    device.lan.dispose();
    devices.remove(device);
    return create(name);
  }

  Future<void> pair(TestDevice a, TestDevice b) async {
    b.lan.onPrompt = (_) async => true;
    final peer = await a.lan.addAddress('127.0.0.1:${b.lan.self.port}');
    await a.lan.connect(peer);
  }

  bool visible(TestDevice device, String id) =>
      device.inbox.conversations.any((conversation) => conversation.id == id);

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'lanflow-conversation-delete-',
    );
  });
  tearDown(() async {
    for (final device in devices) {
      await device.close();
      device.inbox.dispose();
      device.lan.dispose();
    }
    devices.clear();
    await root.delete(recursive: true);
  });

  test(
    'empty deletion syncs despite offline rename and survives restart',
    () async {
      var a = await create('pc');
      final b = await create('phone');
      await pair(a, b);
      final conversation = await a.inbox.createConversation('Empty');
      await a.inbox.syncNow();
      expect(visible(b, conversation.id), isTrue);
      b.inbox.selectConversation(conversation.id);
      await a.inbox.deleteConversation(conversation.id);
      await b.inbox.renameConversation(conversation.id, 'Offline rename');
      await a.inbox.syncNow();
      await b.inbox.syncNow();
      expect(visible(a, conversation.id), isFalse);
      expect(visible(b, conversation.id), isFalse);
      expect(b.inbox.conversationId, defaultConversationId);
      expect(
        b.inbox.store.conversations[conversation.id]!.name,
        'Offline rename',
      );

      a = await restart(a, 'pc');
      await pair(a, b);
      await a.inbox.syncNow();
      expect(visible(a, conversation.id), isFalse);
      expect(visible(b, conversation.id), isFalse);

      await expectLater(
        b.inbox.addText('New message', conversation: conversation.id),
        throwsFormatException,
      );
      final replacement = await b.inbox.createConversation('Offline rename');
      await b.inbox.addText('New message');
      await b.inbox.syncNow();
      expect(visible(a, conversation.id), isFalse);
      expect(visible(b, conversation.id), isFalse);
      expect(visible(a, replacement.id), isTrue);
      await a.inbox.deleteConversation(replacement.id);
      await a.inbox.syncNow();
      expect(visible(a, conversation.id), isFalse);
      expect(visible(b, conversation.id), isFalse);
      expect(await b.inbox.store.conversationIds(conversation.id), isEmpty);
    },
  );

  test(
    'default conversation stays available after clearing its messages',
    () async {
      final a = await create('pc');
      final b = await create('phone');
      await pair(a, b);
      await a.inbox.deleteConversation(defaultConversationId);
      await a.inbox.syncNow();
      expect(visible(a, defaultConversationId), isTrue);
      expect(visible(b, defaultConversationId), isTrue);
      await b.inbox.addText('Reopen self chat');
      await b.inbox.syncNow();
      expect(visible(a, defaultConversationId), isTrue);
      expect(visible(b, defaultConversationId), isTrue);
    },
  );

  test(
    'upgrade publishes old local hiding without deleting newer messages',
    () async {
      var a = await create('pc');
      final b = await create('phone');
      await pair(a, b);
      final empty = await a.inbox.createConversation('Previously deleted');
      final active = await a.inbox.createConversation('Has newer messages');
      await a.inbox.addText('Keep this message');
      await a.inbox.syncNow();
      a.inbox.store.preference(empty.id).hiddenThrough = 0;
      a.inbox.store.preference(active.id).hiddenThrough = 0;
      await a.inbox.store.save();
      expect(visible(a, empty.id), isFalse);
      expect(visible(b, empty.id), isTrue);

      a = await restart(a, 'pc');
      await pair(a, b);
      await a.inbox.syncNow();
      expect(visible(a, empty.id), isFalse);
      expect(visible(b, empty.id), isFalse);
      expect(visible(a, active.id), isTrue);
      expect(visible(b, active.id), isTrue);
      expect(await a.inbox.store.conversationIds(active.id), hasLength(1));
      expect(await b.inbox.store.conversationIds(active.id), hasLength(1));
      expect(a.inbox.store.preference(empty.id).hiddenThrough, isNull);
      expect(a.inbox.store.preference(active.id).hiddenThrough, isNull);
    },
  );
}
