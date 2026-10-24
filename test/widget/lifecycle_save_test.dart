import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/platform/native_core.dart';
import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();
  testWidgets(
    'hiding the app flushes the current draft without waiting for the typing debounce',
    (tester) async {
      await harness.mount(tester);
      await tester.enterText(
        find.byKey(const ValueKey('inbox-composer')),
        '后台前必须保存的草稿',
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (true) {
          final state =
              await NativeCore.run({
                    'op': 'open',
                    'root': harness.directory.path,
                  })
                  as Map;
          if (state['drafts']?[harness.inbox.conversationId] == '后台前必须保存的草稿') {
            break;
          }
          if (DateTime.now().isAfter(deadline)) {
            fail('Lifecycle did not flush the draft');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('inbox-composer')))
            .controller!
            .text,
        '后台前必须保存的草稿',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
