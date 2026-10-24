import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/core/network/discovery.dart';
import 'package:lanflow/core/network/models.dart';

void main() {
  test('discovery activity does not schedule recurring idle probes', () async {
    final timers = <Duration>[];
    final own = Peer(
      id: 'a' * 32,
      name: 'quiet',
      platform: 'android',
      address: '',
      port: 53318,
      fingerprint: 'a' * 64,
    );
    final discovery = DiscoveryService(
      self: () => own,
      onPeer: (_) {},
      onError: (_) {},
      port: 0,
      listenAddress: InternetAddress.loopbackIPv4,
    );
    try {
      await runZoned(
        () async {
          await discovery.start();
          discovery.setActivity(foreground: false);
          await discovery.announce();
          discovery.setActivity(foreground: true);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            timers.add(duration);
            return parent.createTimer(zone, duration, callback);
          },
          createPeriodicTimer: (self, parent, zone, duration, callback) {
            timers.add(duration);
            return parent.createPeriodicTimer(zone, duration, callback);
          },
        ),
      );
      expect(timers.where((d) => d >= const Duration(seconds: 10)), isEmpty);
    } finally {
      discovery.close();
    }
  });

  test(
    'UDP discovers the source address, ignores malformed frames, and answers probes',
    () async {
      final own = Peer(
        id: 'a' * 32,
        name: 'own',
        platform: 'windows',
        address: '127.0.0.1',
        port: 53318,
        fingerprint: 'a' * 64,
      );
      final other = Peer(
        id: 'b' * 32,
        name: 'phone',
        platform: 'android',
        address: 'untrusted-advertised-address',
        port: 53320,
        fingerprint: 'b' * 64,
      );
      final found = Completer<Peer>();
      final errors = <String>[];
      final discovery = DiscoveryService(
        self: () => own,
        onPeer: (peer) {
          if (!found.isCompleted) found.complete(peer);
        },
        onError: errors.add,
        port: 0,
        listenAddress: InternetAddress.loopbackIPv4,
        announceAutomatically: false,
      );
      final socket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final reply = Completer<Map<String, dynamic>>();
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final packet = socket.receive();
        if (packet != null && !reply.isCompleted) {
          reply.complete(
            jsonDecode(utf8.decode(packet.data)) as Map<String, dynamic>,
          );
        }
      });
      try {
        await discovery.start();
        socket.send(
          utf8.encode('malformed'),
          InternetAddress.loopbackIPv4,
          discovery.boundPort,
        );
        socket.send(
          utf8.encode(
            jsonEncode({
              'app': 'lanflow',
              'type': 'discover',
              'device': other.toJson(),
            }),
          ),
          InternetAddress.loopbackIPv4,
          discovery.boundPort,
        );
        final peer = await found.future.timeout(const Duration(seconds: 3));
        expect(peer.id, other.id);
        expect(peer.address, '127.0.0.1');
        final response = await reply.future.timeout(const Duration(seconds: 3));
        expect(response['type'], 'announce');
        expect((response['device'] as Map)['id'], own.id);
        expect(errors, isEmpty);
      } finally {
        discovery.close();
        socket.close();
      }
    },
  );
}
