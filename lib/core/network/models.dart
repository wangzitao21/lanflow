import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

const protocolVersion = 1;
const servicePort = 53318;
const discoveryPort = 53319;

String randomToken([int bytes = 32]) {
  final random = Random.secure();
  return base64UrlEncode(
    List<int>.generate(bytes, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
}

String verificationCode(String first, String second) {
  final values = [first, second]..sort();
  final digest = sha256.convert(utf8.encode(values.join(':'))).bytes;
  final number =
      ((digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3]) %
      1000000;
  return number.toString().padLeft(6, '0');
}

enum MessageKind { text, image, video, file }

enum Delivery { waiting, transferring, complete, failed, cancelled }

class Peer {
  Peer({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
    required this.fingerprint,
    this.inboxVersion = 0,
    this.instanceId = '',
    this.inboxRevision = 0,
    DateTime? lastSeen,
    this.online = true,
  }) : lastSeen = lastSeen ?? DateTime.now();

  final String id;
  String name;
  final String platform;
  String address;
  int port;
  final String fingerprint;
  final int inboxVersion;
  final String instanceId;
  final int inboxRevision;
  DateTime lastSeen;
  bool online;

  factory Peer.fromJson(Map<String, dynamic> json, {String? address}) {
    final fingerprint = json['fingerprint'] as String;
    final id = json['id'] as String;
    final port = json['port'] as int;
    final name = json['name'] as String;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint) ||
        id != fingerprint.substring(0, 32) ||
        port < 1 ||
        port > 65535 ||
        name.isEmpty ||
        name.length > 60 ||
        json['version'] != protocolVersion) {
      throw const FormatException('设备信息无效或协议版本不兼容');
    }
    return Peer(
      id: id,
      name: name,
      platform: json['platform'] as String,
      address: address ?? json['address'] as String? ?? '',
      port: port,
      fingerprint: fingerprint,
      inboxVersion: json['inboxVersion'] as int? ?? 0,
      instanceId: json['instanceId'] as String? ?? '',
      inboxRevision: json['inboxRevision'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': protocolVersion,
    'id': id,
    'name': name,
    'platform': platform,
    'address': address,
    'port': port,
    'fingerprint': fingerprint,
    'inboxVersion': inboxVersion,
    'instanceId': instanceId,
    'inboxRevision': inboxRevision,
  };
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.peerId,
    required this.outgoing,
    required this.kind,
    required this.createdAt,
    this.text = '',
    this.name = '',
    this.size = 0,
    this.path,
    this.delivery = Delivery.waiting,
    this.transferred = 0,
    this.error,
  });

  final String id;
  final String peerId;
  final bool outgoing;
  final MessageKind kind;
  final DateTime createdAt;
  final String text;
  final String name;
  final int size;
  String? path;
  Delivery delivery;
  int transferred;
  String? error;
  double get progress => size == 0 ? 0 : (transferred / size).clamp(0, 1);
  String get preview => kind == MessageKind.text
      ? text
      : '${switch (kind) {
          MessageKind.image => '[图片]',
          MessageKind.video => '[视频]',
          _ => '[文件]',
        }} $name';

  Map<String, dynamic> toJson() => {
    'id': id,
    'peerId': peerId,
    'outgoing': outgoing,
    'kind': kind.name,
    'createdAt': createdAt.toIso8601String(),
    'text': text,
    'name': name,
    'size': size,
    'path': path,
    'delivery': delivery.name,
    'transferred': transferred,
    'error': error,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    var delivery = Delivery.values.byName(json['delivery'] as String);
    final interrupted =
        delivery == Delivery.waiting || delivery == Delivery.transferring;
    if (interrupted) delivery = Delivery.failed;
    return ChatMessage(
      id: json['id'] as String,
      peerId: json['peerId'] as String,
      outgoing: json['outgoing'] as bool,
      kind: MessageKind.values.byName(json['kind'] as String),
      createdAt: DateTime.parse(json['createdAt'] as String),
      text: json['text'] as String? ?? '',
      name: json['name'] as String? ?? '',
      size: json['size'] as int? ?? 0,
      path: json['path'] as String?,
      delivery: delivery,
      transferred: json['transferred'] as int? ?? 0,
      error: interrupted ? '上次传输已中断，请重新发送' : json['error'] as String?,
    );
  }
}

class PeerSession {
  PeerSession({required this.receiveToken, required this.sendToken});
  final String receiveToken;
  final String sendToken;
  Map<String, dynamic> toJson() => {
    'receiveToken': receiveToken,
    'sendToken': sendToken,
  };
  factory PeerSession.fromJson(Map<String, dynamic> json) => PeerSession(
    receiveToken: json['receiveToken'] as String,
    sendToken: json['sendToken'] as String,
  );
}

class IncomingPrompt {
  IncomingPrompt.pair(this.peer, this.code) : file = null;
  IncomingPrompt.file(this.peer, this.file) : code = null;
  final Peer peer;
  final String? code;
  final ChatMessage? file;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
