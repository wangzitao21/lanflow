import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/chat/message_text.dart';
import 'package:lanflow/ui/shared/device_avatar.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  testWidgets(
    'local history stays readable while the network is starting or failed',
    (tester) async {
      await tester.runAsync(() => harness.inbox.addText('本地记录随时可读'));
      harness.lan.ready = false;
      harness.lan.starting = true;
      await harness.mount(tester);
      final message = find.descendant(
        of: find.byKey(const ValueKey('self-chat-history')),
        matching: find.text('本地记录随时可读'),
      );
      expect(message, findsOneWidget);
      expect(
        tester.widget<MessageText>(find.byType(MessageText)).outgoing,
        isTrue,
      );
      expect(find.text('正在打开聊天记录…'), findsNothing);
      harness.lan.starting = false;
      harness.lan.error = '网络接收暂不可用';
      harness.inbox.selectConversation(defaultConversationId);
      await tester.pumpAndSettle();
      expect(message, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'history keeps its anchor across the 40-message boundary and conversation switches',
    (tester) async {
      void history(int count) {
        harness.inbox.store.applySnapshot({
          'revision': harness.inbox.store.revision + 1,
          'profiles': Map.of(harness.inbox.store.profiles),
          'conversations': {
            'other-conversation-001': {'name': '另一个会话'},
          },
          'entries': [
            for (var i = 0; i < count; i++)
              {
                'sequence': i + 1,
                'item': InboxItem(
                  id: 'anchored-message-${i.toString().padLeft(5, '0')}',
                  originId: harness.lan.identity.id,
                  originName: harness.lan.name,
                  createdAt: DateTime.utc(
                    2026,
                    10,
                    19,
                  ).add(Duration(seconds: i)),
                  kind: MessageKind.text,
                  text: '需要保留阅读位置的消息 $i',
                ).toJson(),
                'copies': [],
              },
          ],
        });
      }

      history(40);
      await harness.mount(tester);
      final listFinder = find.byKey(const ValueKey('self-chat-history'));
      final list = tester.widget<ListView>(listFinder);
      expect(list.reverse, isTrue);
      list.controller!.jumpTo(650);
      await tester.pumpAndSettle();
      final viewport = tester.getRect(listFinder);
      final anchor = find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('inbox-item-'),
          )
          .evaluate()
          .firstWhere((element) {
            final rect = tester.getRect(find.byWidget(element.widget));
            return rect.top > viewport.top + 30 &&
                rect.bottom < viewport.bottom - 30;
          })
          .widget
          .key!;
      final previousY = tester.getTopLeft(find.byKey(anchor)).dy;
      history(41);
      harness.inbox.selectConversation(defaultConversationId);
      await tester.pumpAndSettle();
      expect(tester.widget<ListView>(listFinder).reverse, isTrue);
      expect(tester.getTopLeft(find.byKey(anchor)).dy, closeTo(previousY, 1));
      final offset = list.controller!.offset;
      harness.inbox.selectConversation('other-conversation-001');
      await tester.pumpAndSettle();
      harness.inbox.selectConversation(defaultConversationId);
      await tester.pumpAndSettle();
      expect(
        tester.widget<ListView>(listFinder).controller!.offset,
        closeTo(offset, 1),
      );
      expect(tester.getTopLeft(find.byKey(anchor)).dy, closeTo(previousY, 1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('typing and instant right-click do not rebuild message history', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await harness.inbox.updateProfile(
        harness.lan.name,
        avatar: base64Encode(png),
      );
      await harness.inbox.addText('右键和输入性能回归');
    });
    await harness.mount(tester);
    final history = tester.widget(
      find.byKey(const ValueKey('self-chat-history')),
    );
    final avatarFinder = find.descendant(
      of: find.byType(DeviceAvatar),
      matching: find.byType(Image),
    );
    final provider = tester.widget<Image>(avatarFinder.first).image;
    expect(tester.widget<Image>(avatarFinder.last).image, same(provider));
    await tester.enterText(
      find.byKey(const ValueKey('inbox-composer')),
      '一段草稿',
    );
    await tester.pump();
    expect(
      tester.widget(find.byKey(const ValueKey('self-chat-history'))),
      same(history),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(
          ValueKey('inbox-item-${harness.inbox.items.single.item.id}'),
        ),
      ),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    final menu = find.byKey(const ValueKey('desktop-context-menu'));
    expect(menu, findsOneWidget);
    expect(find.text('复制文字'), findsOneWidget);
    expect(
      tester.widget(find.byKey(const ValueKey('self-chat-history'))),
      same(history),
    );
    expect(tester.widget<Image>(avatarFinder.last).image, same(provider));
    await gesture.up();
    await tester.tapAt(const Offset(320, 90));
    await tester.pumpAndSettle();
    expect(menu, findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'large histories build the newest viewport without walking old rows',
    (tester) async {
      final created = DateTime.utc(2026, 10, 19);
      harness.inbox.store.applySnapshot({
        'revision': harness.inbox.store.revision + 1,
        'profiles': Map.of(harness.inbox.store.profiles),
        'entries': [
          for (var i = 0; i < 5000; i++)
            {
              'sequence': i + 1,
              'item': InboxItem(
                id: 'performance-message-$i',
                originId: harness.lan.identity.id,
                originName: harness.lan.name,
                createdAt: created.add(Duration(seconds: i)),
                kind: MessageKind.text,
                text: '历史消息 $i',
              ).toJson(),
              'copies': <String>[],
            },
        ],
      });
      await harness.mount(tester);
      expect(find.text('历史消息 4999'), findsWidgets);
      expect(find.text('历史消息 0'), findsNothing);
      expect((harness.inbox as WidgetInbox).statusReads, lessThan(80));
      final history = tester.widget<ListView>(
        find.byKey(const ValueKey('self-chat-history')),
      );
      expect(history.controller!.offset, 0);
      history.controller!.jumpTo(1200);
      await tester.pumpAndSettle();
      expect(history.controller!.offset, 1200);
      expect(find.text('回到最新'), findsOneWidget);
      await tester.tap(find.text('回到最新'));
      await tester.pumpAndSettle();
      expect(history.controller!.offset, 0);
      expect(find.text('回到最新'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('sending after locating a result reveals the sent message', (
    tester,
  ) async {
    await tester.runAsync(() => harness.inbox.addText('old needle'));
    await harness.mount(tester);
    await harness.openGlobalSearch(tester);
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('global-conversation-search'));
    await tester.enterText(search, 'needle');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        ValueKey('search-result-${harness.inbox.items.single.item.id}'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('inbox-composer')),
      'new outgoing message',
    );
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '发送'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(search, findsOneWidget);
    expect(find.text('new outgoing message'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
