import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/files/message_export.dart';
import 'package:lanflow/platform/native_core.dart';
import '../support/test_device.dart';

void main() {
  late Directory root;
  final devices = <TestDevice>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lanflow-organization-');
  });
  tearDown(() async {
    for (final d in devices.reversed) {
      await d.close();
      d.inbox.dispose();
      d.lan.dispose();
    }
    devices.clear();
    await root.delete(recursive: true);
  });
  Future<TestDevice> create(String name) async {
    final d = await TestDevice.create('${root.path}/$name', name);
    devices.add(d);
    return d;
  }

  test(
    'independent favorites survive multi-delete and conversation restore across devices',
    () async {
      final a = await create('source');
      final b = await create('target');
      b.lan.onPrompt = (_) async => true;
      await a.lan.connect(
        await a.lan.addAddress('127.0.0.1:${b.lan.self.port}'),
      );
      final conversation = await a.inbox.createConversation('待整理');
      final first = (await a.inbox.addText('收藏第一条'))!;
      final second = (await a.inbox.addText('收藏第二条'))!;
      final untouched = (await a.inbox.addText('保留第三条'))!;
      await a.inbox.setFavorites([first.item.id, second.item.id], true);
      await a.inbox.renameConversation(conversation.id, 'Research 工作');
      await a.inbox.syncNow();
      expect(
        b.inbox.store.favorites,
        containsAll([first.item.id, second.item.id]),
      );
      expect(b.inbox.store.conversations[conversation.id]!.name, 'Research 工作');
      await a.inbox.deleteItems([first.item.id, second.item.id]);
      await a.inbox.syncNow();
      expect(a.inbox.items.single.item.id, untouched.item.id);
      expect(b.inbox.items.single.item.id, untouched.item.id);
      await a.inbox.restoreItem(first.item);
      final restored = a.inbox.items.firstWhere(
        (e) => e.item.text == first.item.text,
      );
      expect(restored.item.id, isNot(first.item.id));
      expect(a.inbox.isFavorite(restored.item.id), isFalse);
      expect(a.inbox.favoriteEntries.length, 2);
      await a.inbox.syncNow();
      expect(b.inbox.isFavorite(restored.item.id), isFalse);
      expect(b.inbox.favoriteEntries.length, 2);
      await a.inbox.setFavorites([first.item.id], false);
      await a.inbox.syncNow();
      expect(b.inbox.isFavorite(first.item.id), isFalse);
      expect(b.inbox.favoriteEntries.single.originalMessageId, second.item.id);
    },
  );

  test('invalid multi-delete rolls back the entire selection', () async {
    final d = await create('atomic');
    final entry = (await d.inbox.addText('不能部分删除'))!;
    await expectLater(
      NativeCore.run({
        'op': 'delete_many',
        'root': d.inbox.store.directory.path,
        'ids': [entry.item.id, '../invalid'],
        'knownRevision': d.inbox.store.revision,
      }),
      throwsStateError,
    );
    await d.inbox.store.refresh();
    expect(d.inbox.store.find(entry.item.id), isNotNull);
    expect(await d.inbox.store.recentlyDeleted(), isEmpty);
  });

  test(
    'message export contains original attachment bytes and portable metadata',
    () async {
      final d = await create('export');
      final source = File('${root.path}/same-name.txt');
      await source.writeAsString('ORIGINAL');
      final attachment = await d.inbox.addFile(source.path);
      final preview = await d.inbox.store.fileForOpening(attachment.item);
      await preview.writeAsString('MODIFIED');
      final text = (await d.inbox.addText('用户原文 English 中文'))!;
      final temp = await Directory('${root.path}/exports').create();
      final zip = await exportMessages([
        text.item.toJson(),
        {
          ...attachment.item.toJson(),
          'sourcePath': (await d.inbox.store.fileForExport(
            attachment.item,
          )).path,
        },
      ], temp);
      final stream = InputFileStream(zip.path);
      try {
        final archive = ZipDecoder().decodeStream(stream);
        final metadata =
            jsonDecode(utf8.decode(archive.findFile('messages.json')!.content))
                as List;
        expect(metadata[0]['text'], '用户原文 English 中文');
        expect(metadata[1].containsKey('sourcePath'), isFalse);
        expect(
          utf8.decode(
            archive.findFile(metadata[1]['attachment'] as String)!.content,
          ),
          'ORIGINAL',
        );
        expect(archive.findFile('messages.txt'), isNotNull);
      } finally {
        await stream.close();
      }
    },
  );
}
