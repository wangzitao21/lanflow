import 'dart:io';

/// A passive snapshot of OS routing information. Unknown routes stay usable;
/// rejecting a reachable LAN, VPN or custom NAS is worse than a failed attempt.
class NetworkState {
  const NetworkState({
    this.available = true,
    this.fingerprint = '',
    this.localNetworkAvailable,
    this.routes = const [],
  });

  final bool available;
  final String fingerprint;
  final bool? localNetworkAvailable;
  final List<NetworkRoute> routes;

  factory NetworkState.fromMap(Map value) => NetworkState(
    available: value['available'] != false,
    fingerprint: value['fingerprint'] is String
        ? value['fingerprint'] as String
        : '',
    localNetworkAvailable: value['localNetworkAvailable'] is bool
        ? value['localNetworkAvailable'] as bool
        : null,
    routes: [
      for (final entry
          in value['routes'] is List ? value['routes'] as List : const [])
        if (entry is Map)
          if (NetworkRoute.fromMap(entry) case final NetworkRoute route) route,
    ],
  );

  bool get canDiscover => available && localNetworkAvailable != false;

  bool canReach(Uri endpoint) {
    if (!available) return false;
    if (localNetworkAvailable != false) return true;
    // Never perform DNS or a connectivity probe on the sending path. Hostnames,
    // IPv6 and public NAS addresses may be routed in ways we cannot infer here.
    final address = InternetAddress.tryParse(endpoint.host);
    if (address == null || address.type != InternetAddressType.IPv4) {
      return true;
    }
    final bytes = address.rawAddress;
    final private =
        bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 169 && bytes[1] == 254);
    if (!private) return true;
    // A cellular default route does not prove that a private LAN is reachable.
    // An explicit route does, even on a device whose transport is unfamiliar.
    return routes.any(
      (route) => route.prefixLength > 0 && route.contains(address),
    );
  }

  bool sameNetwork(NetworkState other) =>
      available == other.available &&
      fingerprint == other.fingerprint &&
      localNetworkAvailable == other.localNetworkAvailable &&
      routes.length == other.routes.length &&
      routes.every(
        (route) => other.routes.any((other) => route.sameRoute(other)),
      );
}

class NetworkRoute {
  const NetworkRoute(this.destination, this.prefixLength);
  final InternetAddress destination;
  final int prefixLength;

  static NetworkRoute? fromMap(Map value) {
    final destination = value['destination'];
    final prefix = value['prefixLength'];
    if (destination is! String || prefix is! int) return null;
    final address = InternetAddress.tryParse(destination);
    if (address == null ||
        prefix < 0 ||
        prefix > address.rawAddress.length * 8) {
      return null;
    }
    return NetworkRoute(address, prefix);
  }

  bool contains(InternetAddress address) {
    final bytes = address.rawAddress;
    final network = destination.rawAddress;
    if (bytes.length != network.length) return false;
    for (var index = 0; index < bytes.length; index++) {
      final bits = (prefixLength - index * 8).clamp(0, 8);
      if (bits == 0) return true;
      final mask = (0xff << (8 - bits)) & 0xff;
      if ((bytes[index] & mask) != (network[index] & mask)) return false;
    }
    return true;
  }

  bool sameRoute(NetworkRoute other) =>
      destination == other.destination && prefixLength == other.prefixLength;
}
