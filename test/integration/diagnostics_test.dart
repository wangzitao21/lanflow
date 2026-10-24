import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import '../support/test_device.dart';

void main() {
  test(
    'diagnostics contain useful counts without messages drafts identities tokens filenames or raw errors',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'private-diagnostics-root-',
      );
      final device = await TestDevice.create(root.path, 'PRIVATE-DEVICE-NAME');
      try {
        final entry = (await device.inbox.addText('PRIVATE-MESSAGE-TEXT'))!;
        device.inbox.setDraft('PRIVATE-DRAFT-TEXT');
        await device.inbox.setFavorites([entry.item.id], true);
        final peerId = 'b' * 32;
        final token = 'c' * 43;
        device.lan.sessions[peerId] = PeerSession(
          receiveToken: token,
          sendToken: token,
        );
        device.inbox.statuses['device:$peerId'] = SyncStatus()
          ..online = false
          ..needsAttention = true
          ..errorCategory = 'authentication'
          ..error =
              'PRIVATE-ERROR https://private-host:1234 Bearer $token ${root.path}';
        final diagnostics = device.inbox.diagnostics();
        expect(diagnostics['messages'], 1);
        expect(diagnostics['favorites'], 1);
        expect(diagnostics['pairedDevices'], 1);
        expect(diagnostics['errorCategories'], ['authentication']);
        final encoded = jsonEncode(diagnostics);
        for (final secret in [
          root.path,
          'private-diagnostics-root',
          entry.item.id,
          device.lan.identity.id,
          peerId,
          token,
          'PRIVATE-DEVICE-NAME',
          'PRIVATE-MESSAGE-TEXT',
          'PRIVATE-DRAFT-TEXT',
          'PRIVATE-ERROR',
          'private-host',
        ]) {
          expect(encoded.contains(secret), isFalse, reason: secret);
        }
      } finally {
        await device.close();
        device.inbox.dispose();
        device.lan.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
