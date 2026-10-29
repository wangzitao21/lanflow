import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/core/storage/storage_startup.dart';
import 'package:path/path.dart' as p;

import '../support/test_device.dart';

void main() {
  test(
    'ordinary restarts retain the selected data, preferences, identity and pairings',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'lanflow-real-restart-',
      );
      final dataRoot = p.join(temporary.path, 'Documents', 'LanFlow');
      final env = {'APPDATA': p.join(temporary.path, 'AppData')};
      TestDevice? device;
      try {
        final first = await StorageStartup.resolve(
          windows: true,
          environment: {...env, 'LANFLOW_DATA_DIR': dataRoot},
          resolveDocuments: () async =>
              Directory(p.join(temporary.path, 'Documents')),
        );
        device = await TestDevice.create(first.root.path, 'Persistent device');
        final identity = device.lan.identity.id;
        final entry = (await device.inbox.addText('重启后仍然存在'))!;
        await device.inbox.setFavorites([entry.item.id], true);
        device.inbox.setDraft('重启后的草稿');
        await device.inbox.setAppearance('dark');
        await device.inbox.setLanguage('en');
        final peer = 'b' * 32;
        device.lan.peers[peer] = Peer(
          id: peer,
          name: 'Saved peer',
          platform: 'windows',
          address: '127.0.0.1',
          port: 9,
          fingerprint: 'b' * 64,
          online: false,
        );
        device.lan.sessions[peer] = PeerSession(
          receiveToken: 'saved-token',
          sendToken: 'remote-token',
        );
        await device.close();
        device.inbox.dispose();
        device.lan.dispose();
        device = null;
        await first.location.activate(first.root);
        await first.location.confirm();
        for (var restart = 0; restart < 3; restart++) {
          final next = await StorageStartup.resolve(
            windows: true,
            environment: env,
            resolveDocuments: () =>
                throw StateError('Must use the saved selection'),
          );
          expect(next.root.path, dataRoot);
          device = await TestDevice.create(next.root.path, null);
          expect(device.lan.identity.id, identity);
          expect(device.lan.name, 'Persistent device');
          expect(device.lan.sessions[peer]?.receiveToken, 'saved-token');
          expect(device.lan.peers[peer]?.name, 'Saved peer');
          expect(device.inbox.items.single.item.text, '重启后仍然存在');
          expect(
            device.inbox.favoriteEntries.single.originalMessageId,
            entry.item.id,
          );
          expect(device.inbox.store.draft, '重启后的草稿');
          expect(device.inbox.appearance.value, 'dark');
          expect(device.inbox.language.value, 'en');
          await device.close();
          device.inbox.dispose();
          device.lan.dispose();
          device = null;
        }
      } finally {
        if (device != null) {
          await device.close();
          device.inbox.dispose();
          device.lan.dispose();
        }
        await temporary.delete(recursive: true);
      }
    },
  );
}
