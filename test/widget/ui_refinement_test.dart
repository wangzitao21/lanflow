import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/models.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  testWidgets(
    'connection labels stay still during background synchronization',
    (tester) async {
      final id = 'e' * 32;
      harness.lan.sessions[id] = PeerSession(
        receiveToken: 'a' * 43,
        sendToken: 'b' * 43,
      );
      final status = harness.inbox.statuses['device:$id'] = SyncStatus()
        ..online = true;
      await harness.mount(tester);
      for (final busy in [true, false, true, false]) {
        status.busy = busy;
        status.error = '暂时无法同步';
        status.needsAttention = true;
        harness.inbox.activity.value++;
        await tester.pump();
        expect(find.text('1/1 台在线'), findsOneWidget);
        expect(find.text('同步失败'), findsNothing);
        expect(find.textContaining('正在同步'), findsNothing);
      }
      await tester.tap(find.byTooltip('我的设备').first);
      await tester.pumpAndSettle();
      for (final busy in [true, false]) {
        status.busy = busy;
        harness.inbox.activity.value++;
        await tester.pump();
        expect(find.text('已连接'), findsOneWidget);
        expect(find.textContaining('正在同步'), findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'an offline binding can be removed without deleting local messages',
    (tester) async {
      final id = 'f' * 32;
      harness.lan.sessions[id] = PeerSession(
        receiveToken: 'a' * 43,
        sendToken: 'b' * 43,
      );
      await tester.runAsync(() => harness.inbox.addText('保留在本机的内容'));
      await harness.mount(tester);
      await tester.tap(find.byTooltip('我的设备').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('remove-device:$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(harness.lan.sessions.containsKey(id), isTrue);
      await tester.tap(find.byKey(ValueKey('remove-device:$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '移除'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await harness.waitFor(() => !harness.lan.sessions.containsKey(id));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('remove-device:$id')), findsNothing);
      expect(harness.inbox.items.single.item.text, '保留在本机的内容');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'retrying a draft error writes the draft before clearing the error',
    (tester) async {
      harness.inbox.store.draft = '拿好这份尚未保存的草稿';
      harness.inbox.error = '草稿保存失败：模拟写入失败';
      await harness.mount(tester);
      await tester.runAsync(() async {
        await Function.apply(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '重试'))
              .onPressed!,
          [],
        );
        final reopened = InboxStore(harness.inbox.store.directory);
        await reopened.load();
        expect(reopened.draft, '拿好这份尚未保存的草稿');
        await reopened.close();
      });
      await tester.pumpAndSettle();
      expect(find.text('草稿未保存，请重试'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('short messages and their context menus use compact geometry', (
    tester,
  ) async {
    await tester.runAsync(() => harness.inbox.addText('拿到资料了'));
    await harness.mount(tester);
    final bubble = find.byKey(
      ValueKey('inbox-item-${harness.inbox.items.single.item.id}'),
    );
    expect(tester.getSize(bubble).height, lessThanOrEqualTo(40));
    await tester.tapAt(
      tester.getCenter(bubble),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    final menu = find.byKey(const ValueKey('desktop-context-menu'));
    expect(tester.getSize(menu).width, lessThan(200));
    expect(find.text('复制文字'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
