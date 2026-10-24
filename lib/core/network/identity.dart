import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:lanflow/platform/native_core.dart';

class Identity {
  Identity(this.certificate, this.privateKey) {
    final base64 = certificate
        .split('\n')
        .where((line) => !line.startsWith('---'))
        .join()
        .replaceAll('\r', '');
    fingerprint = sha256.convert(base64Decode(base64)).toString();
  }
  final String certificate;
  final String privateKey;
  late final String fingerprint;
  String get id => fingerprint.substring(0, 32);

  SecurityContext get context => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certificate))
    ..usePrivateKeyBytes(utf8.encode(privateKey));

  static Future<Identity> load(Directory directory) async {
    final file = File('${directory.path}/identity.json');
    if (await file.exists()) {
      final value =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return Identity(
        value['certificate'] as String,
        value['privateKey'] as String,
      );
    }
    final value =
        await NativeCore.run({'op': 'identity', 'root': directory.path}) as Map;
    return Identity(
      value['certificate'] as String,
      value['privateKey'] as String,
    );
  }
}
