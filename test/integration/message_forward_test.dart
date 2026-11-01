import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import '../support/test_device.dart';

void main() {
  late Directory root;
  final devices = <TestDevice>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lanflow-forward-');
  });
  tearDown(() async {
    for (final device in devices.reversed) {
      await device.close();
      device.inbox.dispose();
      device.lan.dispose();
    }
    devices.clear();
    await root.delete(recursive: true);
  });
  Future<TestDevice> create(String name) async {
    final device = await TestDevice.create('${root.path}/$name', name);
    devices.add(device);
    return device;
  }

  test(
    'message settings survive reload with correct upgrade defaults',
    () async {
      final device = await create('preferences');
      expect(device.inbox.store.mergedCopyNumbered, isFalse);
      expect(device.inbox.store.cutForward, isTrue);
      await device.inbox.setMessagePreferences(
        mergedCopyNumbered: true,
        cutForward: false,
      );
      final reloaded = InboxStore(device.inbox.store.directory);
      await reloaded.load();
      expect(reloaded.mergedCopyNumbered, isTrue);
      expect(reloaded.cutForward, isFalse);
    },
  );
  test(
    'forwarded attachment preserves caption quote bytes and syncs the move to a paired device',
    () async {
      final a = await create('a');
      final b = await create('b');
      b.lan.onPrompt = (_) async => true;
      await a.lan.connect(
        await a.lan.addAddress('127.0.0.1:${b.lan.self.port}'),
      );
      final destination = await a.inbox.createConversation('归档');
      a.inbox.selectConversation(defaultConversationId);
      final original = (await a.inbox.addText('原文'))!;
      final quoted = (await a.inbox.addText(
        '引用文字',
        quote: MessageQuote.fromItem(original.item),
      ))!;
      final source = File('${root.path}/report.txt');
      await source.writeAsString('Exact attachment bytes');
      final attachment = await a.inbox.addFile(source.path);
      await a.inbox.editMessage(
        attachment.item,
        text: '附件说明 https://example.com',
        name: 'renamed.txt',
      );
      await a.inbox.forwardMessage(quoted.item, destination.id, cut: false);
      await a.inbox.forwardMessage(attachment.item, destination.id);
      expect(await a.inbox.store.loadEntry(attachment.item.id), isNull);
      expect(await a.inbox.store.loadEntry(quoted.item.id), isNotNull);
      final moved = a.inbox
          .itemsIn(destination.id)
          .firstWhere((entry) => entry.item.isFile);
      expect(moved.item.text, '附件说明 https://example.com');
      expect(moved.item.name, 'renamed.txt');
      expect(
        await (await a.inbox.store.fileForExport(moved.item)).readAsString(),
        'Exact attachment bytes',
      );
      expect(
        a.inbox
            .itemsIn(destination.id)
            .firstWhere((entry) => !entry.item.isFile)
            .item
            .quote!
            .id,
        original.item.id,
      );
      await a.inbox.syncNow();
      final remote = await b.inbox.store.loadEntry(moved.item.id);
      expect(remote!.item.conversationId, destination.id);
      expect(await b.inbox.store.loadEntry(attachment.item.id), isNull);
      expect(
        await (await b.inbox.store.fileForExport(remote.item)).readAsString(),
        'Exact attachment bytes',
      );
    },
  );
}
