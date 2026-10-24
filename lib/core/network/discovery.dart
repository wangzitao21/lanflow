import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lanflow/core/network/models.dart';

class DiscoveryService {
  DiscoveryService({
    required this.self,
    required this.onPeer,
    required this.onError,
    this.port = discoveryPort,
    this.listenAddress,
    this.announceAutomatically = true,
    this.beforeDiscovery,
  });
  final Peer Function() self;
  final void Function(Peer) onPeer;
  final void Function(String) onError;
  final int port;
  final InternetAddress? listenAddress;
  final bool announceAutomatically;
  final Future<void> Function()? beforeDiscovery;
  int get boundPort => _socket!.port;
  final _group = InternetAddress('239.255.77.77');
  RawDatagramSocket? _socket;
  List<NetworkInterface> _interfaces = [];
  final Map<String, NetworkInterface> _memberships = {};
  bool _announcing = false;
  bool _closed = false;
  bool _foreground = true;
  bool _paused = false;

  void setActivity({bool? foreground, bool? paused}) {
    final resumed =
        (foreground == true && !_foreground) || (paused == false && _paused);
    _foreground = foreground ?? _foreground;
    _paused = paused ?? _paused;
    if (resumed && announceAutomatically) unawaited(announce());
  }

  Future<void> start() async {
    if (_closed || _socket != null) return;
    _socket = await RawDatagramSocket.bind(
      listenAddress ?? InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
    );
    try {
      _socket!.broadcastEnabled = true;
      _socket!.multicastHops = 1;
    } on Object {
      close();
      rethrow;
    }
    _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = _socket?.receive()) != null) {
        if (_paused) continue;
        try {
          if (packet!.data.length > 8192) continue;
          final json =
              jsonDecode(utf8.decode(packet.data)) as Map<String, dynamic>;
          if (json['app'] != 'lanflow') continue;
          final peer = Peer.fromJson(
            json['device'] as Map<String, dynamic>,
            address: packet.address.address,
          );
          if (peer.id == self().id) continue;
          onPeer(peer);
          if (json['type'] == 'discover') {
            _send(packet.address, packet.port, 'announce');
          }
        } on Object {
          // LAN broadcasts may belong to other apps or incompatible versions.
        }
      }
    }, onError: (Object error) => onError('设备发现遇到问题：$error'));
    if (!announceAutomatically) return;
    await announce();
  }

  Future<void> _refreshInterfaces() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    if (_closed) return;
    final current = <String, NetworkInterface>{
      for (final interface in interfaces)
        '${interface.index}:${(interface.addresses.map((ip) => ip.address).toList()..sort()).join(',')}':
            interface,
    };
    for (final entry in _memberships.entries.toList()) {
      if (current.containsKey(entry.key)) continue;
      try {
        _socket?.leaveMulticast(_group, entry.value);
      } on Object catch (error) {
        if (error is! SocketException && error is! OSError) rethrow;
        // A disconnected adapter may already have dropped its membership.
      }
      _memberships.remove(entry.key);
    }
    for (final entry in current.entries) {
      // Windows rejects joining the same group twice on one adapter.
      if (_memberships.containsKey(entry.key)) continue;
      try {
        _socket?.joinMulticast(_group, entry.value);
        _memberships[entry.key] = entry.value;
      } on Object catch (error) {
        if (error is! SocketException && error is! OSError) rethrow;
        // Virtual or disconnected adapters must not disable other adapters.
      }
    }
    _interfaces = interfaces;
  }

  void _send(InternetAddress address, int port, String type) {
    final data = utf8.encode(
      jsonEncode({'app': 'lanflow', 'type': type, 'device': self().toJson()}),
    );
    try {
      _socket?.send(data, address, port);
    } on Object catch (error) {
      if (error is! SocketException && error is! OSError) rethrow;
      /* Other interfaces may work. */
    }
  }

  Future<void> announce() async {
    if (_closed || _socket == null || _announcing || _paused) return;
    _announcing = true;
    try {
      await beforeDiscovery?.call();
      if (_closed || _paused) return;
      // Discovery runs on startup, network/user activity and content changes.
      // There is no idle broadcast loop; an explicit probe needs fresh routes.
      await _refreshInterfaces();
      for (final interface in _interfaces) {
        try {
          _socket?.setRawOption(
            RawSocketOption(
              RawSocketOption.levelIPv4,
              RawSocketOption.IPv4MulticastInterface,
              interface.addresses.first.rawAddress,
            ),
          );
          _send(_group, discoveryPort, 'discover');
        } on Object catch (error) {
          if (error is! SocketException && error is! OSError) rethrow;
          /* Interface may have disconnected. */
        }
      }
      _send(InternetAddress('255.255.255.255'), discoveryPort, 'discover');
    } on SocketException catch (error) {
      onError('请检查网络连接：${error.message}');
    } on OSError catch (error) {
      onError('请检查网络连接：${error.message}');
    } finally {
      _announcing = false;
    }
  }

  void close() {
    _closed = true;
    _socket?.close();
    _socket = null;
    _memberships.clear();
    _interfaces = [];
  }
}
