import 'dart:convert';

import 'package:path/path.dart' as p;

import 'package:lanflow/platform/native_core.dart';

Future<String> hashFile(String path) async =>
    await NativeCore.run({'op': 'hash', 'path': path}) as String;

// Keep this closure outside the controller: it must never capture live sockets.
Future<String> hashFileInBackground(String path) => hashFile(path);

String safeFileName(String name) {
  var result = p
      .basename(name.replaceAll('\\', '/'))
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (result.isEmpty || result == '.' || result == '..') result = 'file';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(result)) {
    result = '_$result';
  }
  var bytes = utf8.encode(result).length;
  if (bytes <= 240) return result;
  final runes = result.runes.toList();
  var start = 0;
  while (bytes > 240) {
    bytes -= utf8.encode(String.fromCharCode(runes[start++])).length;
  }
  return String.fromCharCodes(runes.skip(start));
}
