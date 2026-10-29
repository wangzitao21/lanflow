import 'dart:io';

// Exercise the folder picker without opening a native dialog.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/widget_harness.dart';

class _DirectorySelector extends FileSelectorPlatform {
  _DirectorySelector(this.path);
  final String path;
  @override
  Future<String?> getDirectoryPath({
    String? initialDirectory,
    String? confirmButtonText,
  }) async => path;
}

void main() {
  final harness = WidgetTestHarness();
  late FileSelectorPlatform previous;
  setUp(() {
    previous = FileSelectorPlatform.instance;
  });
  tearDown(() {
    FileSelectorPlatform.instance = previous;
  });

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
    // The storage panel remains busy while its confirmation is open.
    await tester.pump(const Duration(milliseconds: 300));
  }

  for (final existing in [false, true]) {
    testWidgets(
      'selected directory is used exactly; existing data: $existing',
      (tester) async {
        final selected = Directory(
          p.join(harness.directory.path, 'custom-data-name'),
        );
        await tester.runAsync(() async {
          await selected.create();
          if (existing) {
            await Directory(
              p.join(selected.path, 'system', 'device'),
            ).create(recursive: true);
            await File(
              p.join(selected.path, 'system', 'messages.sqlite3'),
            ).writeAsString('database');
            await File(
              p.join(selected.path, 'system', 'device', 'identity.json'),
            ).writeAsString('identity');
          }
        });
        FileSelectorPlatform.instance = _DirectorySelector(selected.path);
        final calls = <({String path, bool migrate, bool create})>[];
        harness.inbox.relocateStorage =
            (path, migrate, {bool createIfEmpty = false}) async {
              calls.add((path: path, migrate: migrate, create: createIfEmpty));
            };
        await harness.mount(tester);
        await tester.tap(find.byTooltip('设置'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-page-storage')));
        await tester.pump();
        await settleIo(tester);
        await tester.ensureVisible(find.text('更改位置'));
        await tester.runAsync(() => tester.tap(find.text('更改位置')));
        await settleIo(tester);
        expect(find.text(selected.path), findsOneWidget);
        await tester.tap(find.text('使用新位置的数据'));
        await settleIo(tester);
        if (existing) {
          expect(find.text('新位置没有数据'), findsNothing);
          expect(calls.single, (
            path: selected.path,
            migrate: false,
            create: false,
          ));
        } else {
          expect(find.text('新位置没有数据'), findsOneWidget);
          expect(calls, isEmpty);
          await tester.tap(find.widgetWithText(TextButton, '取消').last);
          await settleIo(tester);
          expect(calls, isEmpty);
          expect(await tester.runAsync(() => selected.list().isEmpty), true);
          await tester.runAsync(() => tester.tap(find.text('更改位置')));
          await settleIo(tester);
          await tester.tap(find.text('使用新位置的数据'));
          await settleIo(tester);
          await tester.tap(find.text('新建数据'));
          await settleIo(tester);
          expect(calls.single, (
            path: selected.path,
            migrate: false,
            create: true,
          ));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
