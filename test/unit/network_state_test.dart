import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/network/network_state.dart';

void main() {
  test('only known cellular-only routes suppress private IPv4 endpoints', () {
    const cellular = NetworkState(localNetworkAvailable: false);
    for (final host in [
      '10.1.2.3',
      '172.16.1.2',
      '172.31.255.254',
      '192.168.1.9',
      '169.254.1.9',
    ]) {
      expect(cellular.canReach(Uri(scheme: 'https', host: host)), isFalse);
      expect(
        const NetworkState().canReach(Uri(scheme: 'https', host: host)),
        isTrue,
      );
    }
    for (final host in [
      '8.8.8.8',
      '127.0.0.1',
      '100.64.1.2',
      '172.32.1.2',
      'nas.local',
      'fd00::1',
      '2001:db8::1',
    ]) {
      expect(cellular.canReach(Uri(scheme: 'https', host: host)), isTrue);
    }
    expect(cellular.canDiscover, isFalse);
    expect(
      const NetworkState(
        available: false,
      ).canReach(Uri.parse('https://nas.local')),
      isFalse,
    );
  });

  test(
    'specific routes preserve custom private networks and partial prefixes',
    () {
      final routed = NetworkState.fromMap({
        'available': true,
        'localNetworkAvailable': false,
        'routes': [
          {'destination': '0.0.0.0', 'prefixLength': 0},
          {'destination': '192.168.32.0', 'prefixLength': 20},
        ],
      });
      expect(routed.canReach(Uri.parse('https://192.168.47.255')), isTrue);
      expect(routed.canReach(Uri.parse('https://192.168.48.1')), isFalse);
      expect(routed.canReach(Uri.parse('https://10.1.2.3')), isFalse);
      expect(
        const NetworkState(
          localNetworkAvailable: true,
        ).canReach(Uri.parse('https://10.1.2.3')),
        isTrue,
      );
    },
  );

  test(
    'unknown payloads fail open and identical route snapshots compare equal',
    () {
      final unknown = NetworkState.fromMap({
        'routes': [
          {'destination': 'broken', 'prefixLength': 50},
        ],
      });
      expect(unknown.canReach(Uri.parse('https://192.168.1.2')), isTrue);
      final first = NetworkState.fromMap({
        'fingerprint': 'wifi',
        'localNetworkAvailable': true,
        'routes': [
          {'destination': '192.168.1.0', 'prefixLength': 24},
        ],
      });
      final second = NetworkState.fromMap({
        'fingerprint': 'wifi',
        'localNetworkAvailable': true,
        'routes': [
          {'destination': '192.168.1.0', 'prefixLength': 24},
        ],
      });
      expect(first.sameNetwork(second), isTrue);
      expect(
        first.sameNetwork(const NetworkState(fingerprint: 'cellular')),
        isFalse,
      );
    },
  );
}
