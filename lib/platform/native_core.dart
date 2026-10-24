import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

typedef _CallNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _CallDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class NativeCoreError extends StateError {
  NativeCoreError(super.message, this.status, [this.category = 'unknown']);
  final int status;
  final String category;
  bool get transient => const {'offline', 'timeout', 'busy'}.contains(category);
}

class _Library {
  _Library() {
    final name = Platform.isWindows ? 'lanflow_core.dll' : 'liblanflow_core.so';
    final candidates = [
      if (Platform.isAndroid) name,
      p.join(p.dirname(Platform.resolvedExecutable), name),
      p.join(Directory.current.path, 'build', 'native', name),
    ];
    Object? error;
    for (final path in candidates) {
      try {
        final library = DynamicLibrary.open(path);
        call = library.lookupFunction<_CallNative, _CallDart>('lanflow_call');
        free = library.lookupFunction<_FreeNative, _FreeDart>('lanflow_free');
        return;
      } on Object catch (e) {
        error = e;
      }
    }
    throw StateError('Rust 核心加载失败：$error');
  }
  late final _CallDart call;
  late final _FreeDart free;
  static final instance = _Library();
}

dynamic _invoke(Map<String, dynamic> request) {
  final library = _Library.instance;
  final input = jsonEncode(request).toNativeUtf8();
  try {
    final output = library.call(input);
    try {
      final response =
          jsonDecode(output.toDartString()) as Map<String, dynamic>;
      if (response['ok'] != true) {
        throw NativeCoreError(
          response['error'] as String,
          response['status'] as int? ?? 400,
          response['category'] as String? ?? 'unknown',
        );
      }
      return response['value'];
    } finally {
      library.free(output);
    }
  } finally {
    calloc.free(input);
  }
}

void _worker(SendPort parent) {
  final receive = ReceivePort();
  parent.send(receive.sendPort);
  receive.listen((dynamic message) {
    final values = message as List;
    final reply = values[1] as SendPort;
    try {
      reply.send([true, _invoke(Map<String, dynamic>.from(values[0] as Map))]);
    } on Object catch (error) {
      reply.send([
        false,
        error is StateError ? error.message : error.toString(),
        error is NativeCoreError ? error.status : 400,
        error is NativeCoreError ? error.category : 'unknown',
      ]);
    }
  });
}

class NativeCore {
  static Future<SendPort>? _port;
  static Future<SendPort> _start() async {
    final ready = ReceivePort();
    await Isolate.spawn(
      _worker,
      ready.sendPort,
      debugName: 'LanFlow Rust storage',
    );
    final port = await ready.first as SendPort;
    ready.close();
    return port;
  }

  static Future<dynamic> run(Map<String, dynamic> request) async {
    if ((request['op'] as String).startsWith('blob_') ||
        const {
          'sync',
          'hash',
          'import_file',
          'identity',
          'storage_stats',
          'clear_preview_cache',
          'cancel_sync',
          'search_messages',
          'apply',
        }.contains(request['op'])) {
      // Network and large file work never hold up the storage worker or UI.
      return Isolate.run(() => _invoke(request));
    }
    final port = await (_port ??= _start());
    final reply = ReceivePort();
    port.send([request, reply.sendPort]);
    final result = await reply.first as List;
    reply.close();
    if (result.first != true) {
      throw NativeCoreError(
        result[1] as String,
        result[2] as int,
        result[3] as String,
      );
    }
    return result[1];
  }
}
