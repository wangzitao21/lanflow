import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/core/storage/local_store.dart';
import 'package:lanflow/core/storage/storage_layout.dart';

class TestDevice {
  TestDevice(this.lan, this.inbox);
  final LanController lan;
  final InboxController inbox;
  static Future<TestDevice> create(
    String path,
    String? name, {
    bool automaticSync = false,
  }) async {
    final lan = LanController(
      store: LocalStore(Directory(path)),
      receiveDirectory: StorageLayout.received(Directory(path)),
      enableDiscovery: false,
      preferredPort: 0,
      bindAddress: InternetAddress.loopbackIPv4,
      initialName: name,
    );
    await lan.start();
    expect(lan.ready, isTrue, reason: lan.error);
    final inbox = InboxController(
      lan: lan,
      store: InboxStore(Directory(path)),
      automaticSync: automaticSync,
    );
    await inbox.start();
    expect(inbox.ready, isTrue, reason: inbox.error);
    return TestDevice(lan, inbox);
  }

  Future<void> close() async {
    await inbox.close();
    await lan.close();
  }
}
