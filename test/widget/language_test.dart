import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/ui/chat/message_text.dart';
import 'package:lanflow/ui/chat/sync_feedback.dart';
import 'package:lanflow/ui/shared/app_root.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/inbox_labels.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  void expectEnglishProductCopy(WidgetTester tester) {
    final chinese = RegExp(r'[\u4e00-\u9fff]');
    final untranslated = <String>[
      for (final widget in tester.widgetList<Text>(find.byType(Text)))
        if (widget.data != null &&
            widget.data != '简体中文' &&
            chinese.hasMatch(widget.data!))
          widget.data!,
      for (final widget in tester.widgetList<Tooltip>(find.byType(Tooltip)))
        if (widget.message != null && chinese.hasMatch(widget.message!))
          widget.message!,
      for (final widget in tester.widgetList<TextField>(find.byType(TextField)))
        for (final value in [
          widget.decoration?.hintText,
          widget.decoration?.labelText,
        ])
          if (value != null && chinese.hasMatch(value)) value,
    ];
    expect(
      untranslated,
      isEmpty,
      reason: 'Product copy must follow the selected language',
    );
  }

  test(
    'product templates preserve user values and localize composite status',
    () {
      expect(
        translateProductText(
          '移除 {name}',
          language: 'en',
          values: {'name': '设置'},
        ),
        'Remove 设置',
      );
      expect(
        translateProductText('已同步 1/3 · 等待设备上线', language: 'en'),
        'Synced 1/3 · Waiting for device',
      );
      expect(
        translateProductText(
          '删除 {count} 条消息？',
          language: 'zh',
          values: {'count': 3},
        ),
        '删除 3 条消息？',
      );
    },
  );

  testWidgets(
    'language switches immediately, persists and preserves user content',
    (tester) async {
      final nativeLanguages = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lanflow/desktop'), (
            call,
          ) async {
            if (call.method == 'setLanguage') {
              nativeLanguages.add(call.arguments as String);
            }
            return null;
          });
      await tester.runAsync(() => harness.inbox.addText('设置'));
      await harness.mount(tester);
      final editor = find.byKey(const ValueKey('inbox-composer'));
      await tester.enterText(editor, '未发送的中文草稿');
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final english = find.byKey(const ValueKey('language-en'));
      await tester.ensureVisible(english);
      await tester.runAsync(() async {
        tester.widget<ChoiceChip>(english).onSelected!(true);
        await harness.waitFor(() => harness.inbox.language.value == 'en');
        await harness.inbox.store.flush();
      });
      await tester.pumpAndSettle();
      expect(find.text('Language'), findsOneWidget);
      expect(find.text('Preferences'), findsNWidgets(2));
      expect(find.text('English'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('我的 Windows'),
        -120,
        scrollable: find.descendant(
          of: find.byKey(const PageStorageKey('preferences-form')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('我的 Windows'), findsOneWidget);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
        const Locale('en'),
      );
      if (Platform.isWindows) expect(nativeLanguages.last, 'en');
      await tester.runAsync(() async {
        final preferences = InboxStore(harness.directory);
        await preferences.loadPreferences();
        expect(preferences.language, 'en');
      });
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).controller!.text, '未发送的中文草稿');
      expect(
        tester.widget<TextField>(editor).decoration!.hintText,
        'Write a message…',
      );
      expect(tester.widget<MessageText>(find.byType(MessageText)).text, '设置');
      expect(find.text('Saved messages'), findsNWidgets(2));
      await tester.runAsync(() => harness.inbox.setLanguage('zh'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).decoration!.hintText, '发点什么…');
      if (Platform.isWindows) expect(nativeLanguages.last, 'zh');
      expect(tester.widget<MessageText>(find.byType(MessageText)).text, '设置');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'English desktop message actions fit and preserve the original message',
    (tester) async {
      await tester.runAsync(() async {
        await harness.inbox.addText('复制文字');
        await harness.inbox.setLanguage('en');
      });
      await harness.mount(tester);
      final message = find.byKey(
        ValueKey('inbox-item-${harness.inbox.items.single.item.id}'),
      );
      await tester.tapAt(
        tester.getCenter(message),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('Sync details'), findsOneWidget);
      expect(find.text('Select messages'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(tester.widget<MessageText>(find.byType(MessageText)).text, '复制文字');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'English settings and selection remain usable on a small phone with large text',
    (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.runAsync(() async {
        await harness.inbox.addText('选择后仍然保留的消息');
        await harness.inbox.setLanguage('en');
      });
      await harness.mount(
        tester,
        size: const Size(320, 640),
        platform: TargetPlatform.android,
      );
      expect(tester.takeException(), isNull);
      final title = tester.getRect(find.text('Saved messages'));
      final selectButton = tester.getRect(find.byTooltip('Select messages'));
      expect(title.width, greaterThan(200));
      expect(selectButton.top, greaterThanOrEqualTo(title.bottom));
      await tester.tap(find.byTooltip('Select messages'));
      await tester.pumpAndSettle();
      expect(find.text('0 selected'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byTooltip('Cancel selection'));
      await tester.tap(find.byTooltip('Cancel selection'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      final language = find.byKey(const ValueKey('language-en'));
      await tester.scrollUntilVisible(
        language,
        140,
        scrollable: find.descendant(
          of: find.byKey(const PageStorageKey('preferences-form')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(tester.widget<ChoiceChip>(language).selected, isTrue);
      expect(find.text('Language'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('expired pairing offers the matching device action in English', (
    tester,
  ) async {
    var openedDevices = false;
    await tester.pumpWidget(
      AppRoot(
        language: 'en',
        home: Scaffold(
          body: SyncIssueTile(
            inbox: harness.inbox,
            target: const SyncTarget('device:old', '设置'),
            detail: '设备证书不一致',
            onDevices: () => openedDevices = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Device identity changed. Pair it again.'),
      findsOneWidget,
    );
    expect(find.text('Retry sync'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    await tester.tap(find.text('Pair again'));
    expect(openedDevices, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'missing device labels translate while identical user names remain unchanged',
    (tester) async {
      await tester.pumpWidget(const AppRoot(language: 'en', home: Scaffold()));
      final context = tester.element(find.byType(Scaffold));
      const target = SyncTarget('device:unknown', '已绑定设备');
      expect(syncTargetLabel(context, harness.inbox, target), 'Paired device');
      expect(
        endpointLabel(context, harness.inbox, 'device:missing'),
        'Disconnected device',
      );
      harness.inbox.store.profiles['unknown'] = {'name': '已绑定设备'};
      expect(syncTargetLabel(context, harness.inbox, target), '已绑定设备');
      expect(deviceLabel(context, harness.inbox, 'unknown'), '已绑定设备');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'English settings, storage, deleted items, device and search surfaces are complete',
    (tester) async {
      await tester.runAsync(() async {
        await harness.inbox.updateProfile('Device test');
        await harness.inbox.setLanguage('en');
      });
      await harness.mount(tester);
      expectEnglishProductCopy(tester);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expectEnglishProductCopy(tester);
      final automatic = find.byKey(const ValueKey('automatic-sync'));
      await tester.scrollUntilVisible(
        automatic,
        140,
        scrollable: find.descendant(
          of: find.byKey(const PageStorageKey('preferences-form')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.runAsync(() async {
        tester.widget<SwitchListTile>(automatic).onChanged!(false);
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      await tester.pumpAndSettle();
      expect(harness.lan.receivingPaused, isTrue);
      expect(
        find.text(
          'Sending and receiving are paused. Resume to continue syncing.',
        ),
        findsOneWidget,
      );
      expectEnglishProductCopy(tester);
      await tester.tap(find.text('Storage').first);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expectEnglishProductCopy(tester);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('desktop-nav-trash')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('No deleted content'), findsOneWidget);
      expectEnglishProductCopy(tester);
      await tester.tap(find.byKey(const ValueKey('desktop-nav-conversations')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('My devices').last);
      await tester.pumpAndSettle();
      expectEnglishProductCopy(tester);
      expect(find.byType(Dialog), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('global-conversation-search')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-filters')), findsNothing);
      expectEnglishProductCopy(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
