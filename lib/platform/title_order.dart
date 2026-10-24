import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

typedef _MapStringNative =
    Int32 Function(
      Pointer<Utf16>,
      Uint32,
      Pointer<Utf16>,
      Int32,
      Pointer<Uint8>,
      Int32,
      Pointer<Void>,
      Pointer<Void>,
      IntPtr,
    );
typedef _MapStringDart =
    int Function(
      Pointer<Utf16>,
      int,
      Pointer<Utf16>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Void>,
      Pointer<Void>,
      int,
    );

/// Reuses collation keys so selection/filter changes never repeat native work.
final class TitleOrder {
  TitleOrder({Future<List<Uint8List>> Function(List<String>)? keyLoader})
    : _keyLoader = keyLoader ?? _platformKeys;

  final Future<List<Uint8List>> Function(List<String>) _keyLoader;
  final _keys = <String, Uint8List>{};
  Future<void> _pending = Future.value();

  static String label(String value) {
    final trimmed = value.trimLeft();
    final end = trimmed.indexOf(RegExp(r'[\r\n]'));
    final line = (end < 0 ? trimmed : trimmed.substring(0, end)).trim();
    return String.fromCharCodes(line.runes.take(256));
  }

  Future<Map<String, int>> ranks(Iterable<String> values) async {
    final titles = values.toSet().toList();
    final operation = _pending.then((_) async {
      final missing = titles
          .where((value) => !_keys.containsKey(value))
          .toList();
      for (var offset = 0; offset < missing.length; offset += 512) {
        final end = (offset + 512).clamp(0, missing.length);
        final batch = missing.sublist(offset, end);
        final keys = await _keyLoader(batch);
        if (keys.length != batch.length) throw StateError('Invalid title keys');
        for (var i = 0; i < batch.length; i++) {
          _keys[batch[i]] = keys[i];
        }
      }
      titles.sort((a, b) {
        final left = _keys[a]!, right = _keys[b]!;
        for (
          var index = 0;
          index < left.length && index < right.length;
          index++
        ) {
          final order = left[index].compareTo(right[index]);
          if (order != 0) return order;
        }
        final order = left.length.compareTo(right.length);
        return order != 0 ? order : a.compareTo(b);
      });
      final result = {for (var i = 0; i < titles.length; i++) titles[i]: i};
      // Prune inside the serialized request, so another request cannot observe
      // keys disappearing between its cache check and its comparison pass.
      if (_keys.length > 8192) {
        final current = titles.toSet();
        _keys.removeWhere((title, _) => !current.contains(title));
      }
      return result;
    });
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  static Future<List<Uint8List>> _platformKeys(List<String> titles) async {
    if (Platform.isWindows) return Isolate.run(() => _windowsKeys(titles));
    if (Platform.isAndroid) {
      final result = await const MethodChannel(
        'lanflow/collation',
      ).invokeListMethod<Uint8List>('titleKeys', titles);
      if (result == null) throw StateError('Title sorting is unavailable');
      return result;
    }
    return [
      for (final title in titles)
        Uint8List.fromList(utf8.encode(title.toLowerCase())),
    ];
  }
}

List<Uint8List> _windowsKeys(List<String> titles) {
  final map = DynamicLibrary.open(
    'kernel32.dll',
  ).lookupFunction<_MapStringNative, _MapStringDart>('LCMapStringEx');
  final locale = 'zh-CN'.toNativeUtf16(allocator: calloc);
  const flags = 0x00000400 | 0x00000001 | 0x00000002;
  try {
    return titles.map((title) {
      if (title.isEmpty) return Uint8List(0);
      final source = title.toNativeUtf16(allocator: calloc);
      Pointer<Uint8> output = nullptr;
      try {
        final size = map(
          locale,
          flags,
          source,
          title.length,
          nullptr,
          0,
          nullptr,
          nullptr,
          0,
        );
        if (size <= 0) throw StateError('Cannot prepare title sorting');
        output = calloc<Uint8>(size);
        final written = map(
          locale,
          flags,
          source,
          title.length,
          output,
          size,
          nullptr,
          nullptr,
          0,
        );
        if (written <= 0) throw StateError('Cannot prepare title sorting');
        return Uint8List.fromList(output.asTypedList(written));
      } finally {
        calloc.free(source);
        if (output != nullptr) calloc.free(output);
      }
    }).toList();
  } finally {
    calloc.free(locale);
  }
}
