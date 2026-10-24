import 'dart:async';
import 'dart:io';

// The selector's public platform interface is used only to control fallback IO.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/platform/app_file_picker.dart';

class _ControlledSelector extends FileSelectorPlatform {
  final entered = Completer<void>();
  final pending = Completer<List<XFile>>();
  int multipleCalls = 0;
  int singleCalls = 0;
  List<XTypeGroup>? groups;
  String? initial;

  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    multipleCalls++;
    groups = acceptedTypeGroups;
    initial = initialDirectory;
    if (!entered.isCompleted) entered.complete();
    return pending.future;
  }

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    singleCalls++;
    return XFile('/fallback/selected.png');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('lanflow/file_picker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late FileSelectorPlatform previous;
  late _ControlledSelector fallback;
  Completer<List<String>>? nativeReply;

  setUp(() {
    previous = FileSelectorPlatform.instance;
    fallback = _ControlledSelector();
    FileSelectorPlatform.instance = fallback;
    nativeReply = null;
    messenger.setMockMethodCallHandler(channel, null);
  });
  tearDown(() async {
    if (!fallback.pending.isCompleted) fallback.pending.complete([]);
    if (nativeReply?.isCompleted == false) nativeReply!.complete([]);
    await Future<void>.delayed(Duration.zero);
    FileSelectorPlatform.instance = previous;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'native open preserves filters, Unicode paths and blocks duplicate selection requests',
    () async {
      nativeReply = Completer<List<String>>();
      final entered = Completer<void>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (!entered.isCompleted) entered.complete();
        return nativeReply!.future;
      });
      final selected = AppFilePicker.openFiles(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: '图片',
            extensions: ['.png', 'jpg'],
            mimeTypes: ['image/*'],
          ),
        ],
        initialDirectory: r'C:\Photos',
        confirmButtonText: '选择',
      );
      await entered.future;
      expect(await AppFilePicker.openFiles(), isEmpty);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'openFiles');
      expect(calls.single.arguments, {
        'multiple': true,
        'initialDirectory': r'C:\Photos',
        'confirmButtonText': '选择',
        'filters': [
          {
            'label': '图片',
            'extensions': ['png', 'jpg'],
          },
        ],
      });
      nativeReply!.complete([r'C:\Photos\图片 空格.png', r'C:\Other\report.txt']);
      expect((await selected).map((file) => file.path), [
        r'C:\Photos\图片 空格.png',
        r'C:\Other\report.txt',
      ]);
      expect(fallback.multipleCalls, 0);
    },
    skip: !Platform.isWindows,
  );

  test(
    'native cancellation resolves empty and a subsequent single-file request can open',
    () async {
      nativeReply = Completer<List<String>>();
      final entered = Completer<void>();
      var cancellations = 0;
      var openings = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'cancelOpenFiles') {
          cancellations++;
          nativeReply!.complete([]);
          return null;
        }
        openings++;
        if (openings == 1) {
          entered.complete();
          return nativeReply!.future;
        }
        expect((call.arguments as Map)['multiple'], isFalse);
        return [r'C:\Photos\single.png'];
      });
      await AppFilePicker.cancelOpenFiles();
      expect(cancellations, 0);
      final pending = AppFilePicker.openFiles();
      await entered.future;
      await AppFilePicker.cancelOpenFiles();
      expect(await pending, isEmpty);
      expect(cancellations, 1);
      expect((await AppFilePicker.openFile())!.path, r'C:\Photos\single.png');
      expect(openings, 2);
    },
    skip: !Platform.isWindows,
  );

  test(
    'native errors and argument failures do not leave selection stuck busy',
    () async {
      var attempts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        attempts++;
        if (attempts == 1) {
          throw PlatformException(
            code: 'FILE_PICKER',
            message: 'Controlled failure',
          );
        }
        return [r'C:\recovered.txt'];
      });
      await expectLater(
        AppFilePicker.openFiles(
          acceptedTypeGroups: const [
            XTypeGroup(mimeTypes: ['image/*']),
          ],
        ),
        throwsArgumentError,
      );
      expect(attempts, 0);
      await expectLater(
        AppFilePicker.openFiles(),
        throwsA(isA<PlatformException>()),
      );
      expect(
        (await AppFilePicker.openFiles()).single.path,
        r'C:\recovered.txt',
      );
      expect(attempts, 2);
    },
    skip: !Platform.isWindows,
  );

  test(
    'fallback awaits the selector before clearing its concurrency guard',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw MissingPluginException(),
      );
      final first = AppFilePicker.openFiles(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Images', extensions: ['png']),
        ],
        initialDirectory: '/fallback',
      );
      await fallback.entered.future;
      expect(await AppFilePicker.openFiles(), isEmpty);
      expect(fallback.multipleCalls, 1);
      expect(fallback.groups!.single.extensions, ['png']);
      expect(fallback.initial, '/fallback');
      fallback.pending.complete([XFile('/fallback/photo.png')]);
      expect((await first).single.path, '/fallback/photo.png');
      expect((await AppFilePicker.openFile())!.path, '/fallback/selected.png');
      expect(fallback.singleCalls, 1);
    },
  );
}
