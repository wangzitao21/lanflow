import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import '../support/test_device.dart';

void main() {
  test(
    'offline text and photos are recovered without reopening or merging same-name chats',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-offline-recovery-',
      );
      final a = await TestDevice.create('${root.path}/pc', 'PC');
      final b = await TestDevice.create('${root.path}/phone', 'Phone');
      try {
        b.lan.onPrompt = (_) async => true;
        await a.lan.connect(
          await a.lan.addAddress('127.0.0.1:${b.lan.self.port}'),
        );
        final old = await a.inbox.createConversation('工作');
        final deleted = (await a.inbox.addText('Delete first'))!;
        await a.inbox.addText('Delete with conversation');
        await a.inbox.syncNow();
        b.inbox.selectConversation(old.id);
        final late = (await b.inbox.addText('Written offline'))!;
        final photo = File('${root.path}/photo.png');
        final bytes = List<int>.generate(4096, (i) => i % 251);
        await photo.writeAsBytes(bytes);
        final file = await b.inbox.addFile(photo.path);
        b.inbox.setDraft('Unsent offline draft');
        await b.inbox.stageFile(photo.path);
        await a.inbox.deleteItem(deleted.item);
        await a.inbox.deleteConversation(old.id);
        final replacement = await a.inbox.createConversation('工作');
        await a.inbox.addText('New conversation');
        for (var pass = 0; pass < 3; pass++) {
          await a.inbox.syncNow();
          await b.inbox.syncNow();
        }
        for (final device in [a, b]) {
          expect(
            device.inbox.conversations
                .where((c) => c.name == '工作')
                .map((c) => c.id),
            [replacement.id],
          );
          expect(await device.inbox.store.conversationIds(old.id), isEmpty);
          expect(device.inbox.store.recoveryCount, 2);
          final page = await device.inbox.store.recoveryPage();
          expect((page['items'] as List).map((v) => v['item']['id']).toSet(), {
            late.item.id,
            file.item.id,
          });
          expect(
            (page['items'] as List).every((v) => v['available'] == true),
            isTrue,
          );
        }
        expect(b.inbox.recoveryDrafts, [old.id]);
        await b.inbox.recoverDraft(old.id, conversation: replacement.id);
        expect(b.inbox.store.draft, 'Unsent offline draft');
        expect(
          b.inbox.store.draftAttachments.single.conversationId,
          replacement.id,
        );
        expect(b.inbox.recoveryDrafts, isEmpty);
        final recovered = (await a.inbox.store.recoveryPage())['items'] as List;
        for (final value in recovered) {
          await a.inbox.recoverMessage(
            RecoveryItem.fromJson(value as Map),
            conversation: replacement.id,
          );
        }
        await a.inbox.syncNow();
        await b.inbox.syncNow();
        for (final device in [a, b]) {
          expect(device.inbox.store.recoveryCount, 0);
          expect(
            await device.inbox.store.conversationIds(replacement.id),
            hasLength(3),
          );
          final entries = await device.inbox.store.loadEntries(
            await device.inbox.store.conversationIds(replacement.id),
          );
          final restored = entries.singleWhere((e) => e.item.isFile);
          expect(
            await device.inbox.store.blob(restored.item.digest).readAsBytes(),
            bytes,
          );
          expect(
            device.inbox.conversations.any((c) => c.id == old.id),
            isFalse,
          );
        }
      } finally {
        for (final d in [a, b]) {
          await d.close();
          d.inbox.dispose();
          d.lan.dispose();
        }
        await root.delete(recursive: true);
      }
    },
  );
}
