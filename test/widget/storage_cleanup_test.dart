import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/ui/chat/desktop_navigation.dart';
import 'package:lanflow/ui/chat/mobile_home.dart';
import 'package:lanflow/ui/settings/recently_deleted_panel.dart';
import 'package:lanflow/ui/settings/storage_dialog.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  Future<void> waitForStorage(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
  }

  testWidgets(
    'recovered user edits are visible from storage without being removed',
    (tester) async {
      late File file;
      await tester.runAsync(() async {
        final directory = Directory(
          '${harness.inbox.store.directory.path}/system/recovered',
        );
        await directory.create(recursive: true);
        file = File('${directory.path}/retained-edit.txt');
        await file.writeAsString('User edit retained for recovery');
      });
      await harness.mount(tester);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('存储管理').first);
      await waitForStorage(tester);
      final recovered = find.byKey(const ValueKey('view-recovered-files'));
      await tester.scrollUntilVisible(
        recovered,
        150,
        scrollable: find
            .descendant(
              of: find.byType(StorageDialog),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(recovered.hitTestable(), findsOneWidget);
      await tester.tap(recovered);
      await tester.pump();
      for (
        var i = 0;
        i < 50 && find.text('retained-edit.txt').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.text('retained-edit.txt'), findsOneWidget);
      await tester.runAsync(() async {
        expect(await file.readAsString(), 'User edit retained for recovery');
        expect(
          (await harness.inbox.store.storageStats())['recovered'],
          greaterThan(0),
        );
      });
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'local trash cleanup requires confirmation and disables duplicate actions',
    (tester) async {
      final calls = <bool>[];
      final gate = Completer<Map<String, dynamic>>();
      harness.inbox.cleanupStorage = (clearTrash) async {
        calls.add(clearTrash);
        return gate.future;
      };
      await tester.runAsync(() async {
        final item = (await harness.inbox.addText(
          'This message remains recoverable until confirmed',
        ))!;
        await harness.inbox.deleteItem(item.item);
        await harness.inbox.setLanguage('en');
      });
      await harness.mount(tester);
      await tester.tap(find.byKey(const ValueKey('desktop-nav-trash')));
      await waitForStorage(tester);
      final clear = find.byKey(const ValueKey('empty-local-trash'));
      expect(find.byType(RecentlyDeletedPanel), findsOneWidget);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Other devices’ recycle bins are unaffected.'),
        findsOneWidget,
      );
      expect(calls, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Empty permanently'));
      await tester.pump();
      expect(calls, [true]);
      expect(tester.widget<TextButton>(clear).onPressed, isNull);
      expect(
        find.byKey(const ValueKey('empty-trash-progress')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('empty-trash-progress')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('desktop-nav-conversations')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(
        tester
            .widget<DesktopNavigation>(find.byType(DesktopNavigation))
            .section,
        MobileSection.trash,
      );
      expect(calls, [true]);
      gate.complete({
        'releasedBytes': 0,
        'removedFiles': 0,
        'keptFiles': 0,
        'clearedTrash': 1,
      });
      await waitForStorage(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'storage keeps unused attachment cleanup but no empty bin entry',
    (tester) async {
      final calls = <bool>[];
      harness.inbox.cleanupStorage = (clearTrash) async {
        calls.add(clearTrash);
        return {
          'releasedBytes': 0,
          'removedFiles': 0,
          'keptFiles': 1,
          'clearedTrash': 0,
        };
      };
      await tester.runAsync(() => harness.inbox.setLanguage('en'));
      await harness.mount(tester);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Storage').first);
      await waitForStorage(tester);
      expect(find.byKey(const ValueKey('empty-local-trash')), findsNothing);
      final unused = find.byKey(const ValueKey('cleanup-unused-attachments'));
      await tester.scrollUntilVisible(
        unused,
        150,
        scrollable: find
            .descendant(
              of: find.byType(StorageDialog),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(unused.hitTestable(), findsOneWidget);
      await tester.tap(unused);
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Conversations and recoverable records are preserved.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Clean up'));
      await waitForStorage(tester);
      expect(calls, [false]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
