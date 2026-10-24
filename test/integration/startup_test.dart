import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/core/storage/local_store.dart';

void main() {
  test(
    'LAN startup and repeated adapter refresh keep the receiver available',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lanflow-startup-',
      );
      final controller = LanController(
        store: LocalStore(directory),
        receiveDirectory: Directory('${directory.path}/received'),
        preferredPort: 0,
        initialName: 'LAN startup regression',
      );
      final client = HttpClient(
        context: SecurityContext(withTrustedRoots: false),
      )..badCertificateCallback = (_, _, _) => true;
      try {
        // Exercise real adapters and multicast, not only the loopback test path.
        await controller.start();
        expect(controller.ready, isTrue, reason: controller.error);
        expect(controller.starting, isFalse);
        expect(controller.error, isNull);
        expect(controller.discoveryWarning, isNull);
        final port = controller.self.port;
        for (var i = 0; i < 12; i++) {
          await controller.refresh();
        }
        await controller.start();
        expect(controller.self.port, port);
        expect(controller.ready, isTrue);
        expect(controller.discoveryWarning, isNull);
        final request = await client.getUrl(
          Uri.parse('https://127.0.0.1:$port/v1/info'),
        );
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);
        final info =
            jsonDecode(await utf8.decoder.bind(response).join()) as Map;
        expect(info['id'], controller.identity.id);
      } finally {
        client.close(force: true);
        await controller.close();
        controller.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'failed startup leaves loading state and can retry after the cause is fixed',
    () async {
      final directory = await Directory.systemTemp.createTemp('lanflow-retry-');
      final blocked = File('${directory.path}/blocked');
      await blocked.writeAsString(
        'A file cannot be used as a receive directory',
      );
      final controller = LanController(
        store: LocalStore(directory),
        receiveDirectory: Directory(blocked.path),
        preferredPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        enableDiscovery: false,
        initialName: 'Retry regression',
      );
      try {
        await controller.start();
        expect(controller.ready, isFalse);
        expect(controller.starting, isFalse);
        expect(controller.error, isNotNull);
        controller.receiveDirectory = Directory('${directory.path}/received');
        await controller.start();
        expect(controller.ready, isTrue, reason: controller.error);
        expect(controller.starting, isFalse);
        expect(controller.error, isNull);
      } finally {
        await controller.close();
        controller.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
