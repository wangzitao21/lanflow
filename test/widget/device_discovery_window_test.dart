import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/ui/devices/device_dialogs.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  testWidgets(
    'device discovery renews only while the panel is visible and active',
    (tester) async {
      final visible = ValueNotifier(true);
      final requests = <Duration>[];
      addTearDown(visible.dispose);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ValueListenableBuilder(
                valueListenable: visible,
                builder: (context, enabled, _) => TickerMode(
                  enabled: enabled,
                  child: DevicePanel(
                    embedded: true,
                    dialogs: DeviceDialogs(
                      context: context,
                      inbox: harness.inbox,
                      showDialog: showDialog,
                      onError: (_) {},
                    ),
                    discoveryWindowRequest: (duration) async {
                      requests.add(duration);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(requests, [const Duration(seconds: 15)]);
      await tester.pump(const Duration(seconds: 10));
      expect(requests, hasLength(2));

      // Retained pages in HomePage's IndexedStack must release their timer.
      visible.value = false;
      await tester.pump();
      await tester.pump(const Duration(minutes: 1));
      expect(requests, hasLength(2));
      visible.value = true;
      await tester.pump();
      expect(requests, hasLength(3));

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump(const Duration(minutes: 1));
      expect(requests, hasLength(3));
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(requests, hasLength(4));

      harness.lan.setReceivingPaused(true);
      await tester.pump(const Duration(minutes: 1));
      expect(requests, hasLength(4));
      harness.lan.setReceivingPaused(false);
      await tester.pump(const Duration(milliseconds: 20));
      expect(requests, hasLength(5));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 1));
      expect(requests, hasLength(5));
      expect(tester.takeException(), isNull);
    },
  );
}
