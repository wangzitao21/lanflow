import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/core/storage/local_store.dart';
import 'package:lanflow/core/storage/storage_layout.dart';
import 'package:lanflow/core/storage/storage_location.dart';
import 'package:lanflow/runtime.dart';

class _FailingSaveStore extends InboxStore {
  _FailingSaveStore(super.directory);
  bool failSave = false;
  @override
  Future<void> save() async {
    if (failSave) {
      throw const FileSystemException('Injected final save failure');
    }
    await super.save();
  }
}

InboxItem _note(String suffix) => InboxItem(
  id: 'retained-message-$suffix',
  originId: 'retained-device-0001',
  originName: 'Local device',
  createdAt: DateTime.utc(2026, 10, 22),
  kind: MessageKind.text,
  text: 'Durable content $suffix',
);

LanController _lan(Directory root) => LanController(
  store: LocalStore(root),
  receiveDirectory: StorageLayout.received(root),
  enableDiscovery: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'retained original session releases history only at disposal and replacement reloads it',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-session-cache-',
      );
      final data = Directory('${root.path}/data');
      final initial = await RuntimeSession.open(
        data,
        enableDiscovery: false,
        preferredPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      RuntimeSession? replacement;
      var disposed = false;
      try {
        await initial.start(acceptShares: false);
        for (var index = 0; index < 48; index++) {
          await initial.inbox.addText('Saved history $index');
        }
        final firstId = initial.inbox.items.first.item.id;
        await initial.inbox.setFavorites([firstId], true);
        final removed = (await initial.inbox.addText(
          'Keep in recently deleted',
        ))!;
        await initial.inbox.deleteItem(removed.item);
        final source = File('${root.path}/attachment.bin');
        await source.writeAsBytes([1, 3, 5, 7]);
        final attachment = await initial.inbox.addFile(source.path);
        initial.inbox.setDraft('Saved local draft');
        await initial.inbox.setLanguage('en');
        final ids = initial.inbox.items.map((entry) => entry.item.id).toSet();
        final heldStore = initial.inbox.store;
        // Reproduce the strong reference retained by the real root widget.
        final heldHost = LanFlowHost(
          session: initial,
          location: StorageLocation(data),
        );
        await initial.close();
        expect(
          heldStore.entries.length,
          49,
          reason: 'close must still expose loaded history until disposal',
        );
        expect(heldStore.find(firstId), isNotNull);
        initial.dispose();
        disposed = true;
        expect(identical(heldHost.session, initial), isTrue);
        expect(identical(heldHost.session.inbox.store, heldStore), isTrue);
        expect(heldStore.entries, isEmpty);
        expect(heldStore.chronologicalEntries, isEmpty);
        expect(heldStore.conversationEntries, isEmpty);
        expect(heldStore.maxConversationSequence, isEmpty);
        expect(ids.every((id) => heldStore.find(id) == null), isTrue);
        expect(heldStore.favorites, isEmpty);
        expect(heldStore.deleted, isEmpty);
        expect(heldStore.profiles, isEmpty);
        expect(heldStore.conversations, isEmpty);
        expect(
          heldStore.blob(attachment.item.digest).path,
          StorageLayout.pending(data, attachment.item.digest),
        );
        expect(heldStore.draft, 'Saved local draft');
        expect(heldStore.language, 'en');

        replacement = await RuntimeSession.open(
          data,
          enableDiscovery: false,
          preferredPort: 0,
          bindAddress: InternetAddress.loopbackIPv4,
        );
        await replacement.start(acceptShares: false);
        expect(
          replacement.inbox.items.map((entry) => entry.item.id).toSet(),
          ids,
        );
        expect(replacement.inbox.store.favorites, contains(firstId));
        expect(replacement.inbox.store.deleted, contains(removed.item.id));
        expect(replacement.inbox.store.draft, 'Saved local draft');
        expect(replacement.inbox.store.language, 'en');
        expect(
          await replacement.inbox.store
              .blob(attachment.item.digest)
              .readAsBytes(),
          [1, 3, 5, 7],
        );
        expect(
          (await replacement.inbox.store.recentlyDeleted()).single.item.id,
          removed.item.id,
        );
        expect(
          heldHost.session.inbox.store.entries,
          isEmpty,
          reason:
              'The initial widget remains reachable without retaining a second history',
        );
      } finally {
        await replacement?.close();
        replacement?.dispose();
        await initial.close();
        if (!disposed) initial.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'disposing an unclosed controller does not discard history or local edits',
    () async {
      final root = await Directory.systemTemp.createTemp('lanflow-live-cache-');
      final store = InboxStore(root);
      final lan = _lan(root);
      final controller = InboxController(
        lan: lan,
        store: store,
        automaticSync: false,
      );
      try {
        await store.load();
        final entry = await store.add(_note('live-0001'));
        store.draft = 'Unclosed local draft';
        controller.dispose();
        expect(store.find(entry.item.id), same(entry));
        expect(store.entries, hasLength(1));
        expect(store.draft, 'Unclosed local draft');
        expect(store.releaseClosedHistory(), isFalse);
      } finally {
        await store.close();
        await lan.close();
        lan.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'failed final save keeps recoverable history, drafts, bindings and settings',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-failed-cache-',
      );
      final store = _FailingSaveStore(root);
      final lan = _lan(root);
      final controller = InboxController(
        lan: lan,
        store: store,
        automaticSync: false,
      );
      var disposed = false;
      try {
        await controller.start();
        expect(controller.ready, isTrue);
        final entry = await store.add(_note('failed-0001'));
        store.draft = 'Pending local draft';
        store.language = 'en';
        store.appearance = 'dark';
        store.hubs.add(
          SyncEndpoint(
            id: 'retained-hub-0001',
            name: 'Retained NAS',
            url: Uri.parse('https://127.0.0.1:53320'),
            fingerprint: 'a' * 64,
            token: 't' * 43,
            isHub: true,
          ),
        );
        store.preference(defaultConversationId).manualUnread = true;
        store.failSave = true;
        await expectLater(
          controller.close(),
          throwsA(isA<FileSystemException>()),
        );
        controller.dispose();
        disposed = true;
        expect(store.releaseClosedHistory(), isFalse);
        expect(store.find(entry.item.id), same(entry));
        expect(store.entries, hasLength(1));
        expect(store.draft, 'Pending local draft');
        expect(store.hubs.single.name, 'Retained NAS');
        expect(store.language, 'en');
        expect(store.appearance, 'dark');
        expect(store.preference(defaultConversationId).manualUnread, isTrue);
        store.failSave = false;
        await store.close();
        final reloaded = InboxStore(root);
        try {
          await reloaded.load();
          expect(reloaded.find(entry.item.id), isNotNull);
          expect(reloaded.draft, 'Pending local draft');
          expect(reloaded.hubs.single.name, 'Retained NAS');
          expect(reloaded.language, 'en');
          expect(reloaded.appearance, 'dark');
          expect(
            reloaded.preference(defaultConversationId).manualUnread,
            isTrue,
          );
        } finally {
          await reloaded.close();
        }
      } finally {
        store.failSave = false;
        await store.close();
        if (!disposed) controller.dispose();
        await lan.close();
        lan.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
