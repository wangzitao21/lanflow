import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import '../support/test_device.dart';

void main() {
  late Directory root;
  final devices = <TestDevice>[];
  setUp(
    () async => root = await Directory.systemTemp.createTemp(
      'lanflow-appearance-order-',
    ),
  );
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

  Future<void> pair(TestDevice a, TestDevice b) async {
    b.lan.onPrompt = (_) async => true;
    await a.lan.connect(await a.lan.addAddress('127.0.0.1:${b.lan.self.port}'));
  }

  Future<TestDevice> restart(TestDevice old, String name) async {
    await old.close();
    old.inbox.dispose();
    old.lan.dispose();
    devices.remove(old);
    return create(name);
  }

  test(
    'device preset and color sync in either direction and survive rename and restart',
    () async {
      var a = await create('pc');
      final b = await create('phone');
      await pair(a, b);
      final id = a.lan.identity.id;
      await a.inbox.updateProfile(
        'My device',
        avatar: '',
        appearance: true,
        preset: 'macos',
        color: 0xFFC66682,
      );
      await a.inbox.syncNow();
      expect(b.inbox.deviceAvatarPreset(id), 'macos');
      expect(b.inbox.deviceAvatarColor(id), 0xFFC66682);
      await a.inbox.updateProfile('Renamed device');
      await a.inbox.syncNow();
      expect(b.inbox.deviceAvatarPreset(id), 'macos');
      expect(b.inbox.deviceAvatarColor(id), 0xFFC66682);
      await b.inbox.setDeviceAppearance(
        id,
        avatar: '',
        preset: 'linux',
        color: 0xFF7E63B5,
      );
      await b.inbox.syncNow();
      expect(a.inbox.deviceAvatarPreset(id), 'linux');
      expect(a.inbox.deviceAvatarColor(id), 0xFF7E63B5);
      a = await restart(a, 'pc');
      expect(a.inbox.deviceAvatarPreset(id), 'linux');
      expect(a.inbox.deviceAvatarColor(id), 0xFF7E63B5);
      await a.inbox.setDeviceAppearance(id, avatar: '');
      await a.inbox.syncNow();
      expect(b.inbox.deviceAvatarPreset(id), isNull);
      expect(b.inbox.deviceAvatarColor(id), isNull);
    },
  );

  test(
    'manual order survives sends, receives, restart, hiding and pinning',
    () async {
      var a = await create('pc');
      final b = await create('phone');
      await pair(a, b);
      final one = await a.inbox.createConversation('One');
      final two = await a.inbox.createConversation('Two');
      final three = await a.inbox.createConversation('Three');
      List<String> order() => a.inbox.conversations.map((c) => c.id).toList();
      expect(order(), [defaultConversationId, one.id, two.id, three.id]);
      await a.inbox.reorderConversation(three.id, 0);
      final manual = order();
      expect(manual, [three.id, defaultConversationId, one.id, two.id]);
      a.inbox.selectConversation(two.id);
      await a.inbox.addText('Sending does not reorder');
      expect(order(), manual);
      await a.inbox.syncNow();
      b.inbox.selectConversation(one.id);
      await b.inbox.addText('Receiving does not reorder');
      await b.inbox.syncNow();
      expect(order(), manual);
      await a.inbox.setConversationPinned(two.id, true);
      final pinned = order();
      expect(pinned, [two.id, three.id, defaultConversationId, one.id]);
      await a.inbox.reorderConversation(two.id, 3);
      expect(order(), pinned, reason: 'Pinned conversations bounce back');
      await a.inbox.reorderConversation(one.id, 0);
      expect(order(), [two.id, one.id, three.id, defaultConversationId]);
      await a.inbox.setConversationPinned(two.id, false);
      expect(order(), [one.id, three.id, defaultConversationId, two.id]);
      final saved = order();
      a = await restart(a, 'pc');
      expect(order(), saved);
      await a.inbox.deleteConversation(three.id);
      expect(order(), [one.id, defaultConversationId, two.id]);
      await a.inbox.reorderConversation(two.id, 0);
      expect(order(), [two.id, one.id, defaultConversationId]);
    },
  );
}
