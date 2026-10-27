import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/app.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/identity.dart';
import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/core/storage/local_store.dart';
import 'package:lanflow/ui/shared/search_text.dart';

class WidgetLan extends LanController {
  WidgetLan({required super.store, required super.receiveDirectory})
    : super(enableDiscovery: false);
  bool stall = false;
  @override
  Future<void> refresh() => stall ? Completer<void>().future : Future.value();
}

class WidgetInbox extends InboxController {
  WidgetInbox({required super.lan, required super.store})
    : super(automaticSync: false);
  @override
  Map<String, dynamic> searchMessages(
    Map<String, dynamic> query, {
    Object? requestGroup,
  }) {
    final pattern = searchPattern(query['query'] as String? ?? '');
    final after = DateTime.tryParse(query['afterDate'] as String? ?? '');
    final before = DateTime.tryParse(query['beforeDate'] as String? ?? '');
    final matches = items.where((entry) {
      final item = entry.item;
      return (pattern == null ||
              pattern.hasMatch(item.isFile ? item.name : item.text)) &&
          (query['conversationId'] == null ||
              item.conversationId == query['conversationId']) &&
          (query['kind'] == null || item.kind.name == query['kind']) &&
          (query['originId'] == null || item.originId == query['originId']) &&
          (after == null || !item.createdAt.isBefore(after)) &&
          (before == null || item.createdAt.isBefore(before)) &&
          (query['favoritesOnly'] != true || isFavorite(item.id));
    }).toList();
    final offset = query['offset'] as int? ?? 0;
    final page = matches
        .skip(offset)
        .take(query['limit'] as int? ?? 100)
        .toList();
    return {
      'ids': page.map((e) => e.item.id).toList(),
      'total': matches.length,
      'more': offset + page.length < matches.length,
      'nextOffset': offset + page.length,
    };
  }

  // File durability is covered by inbox_test; keep UI tests free of background timers.
  @override
  void setDraft(String value) {
    store.draft = value;
  }

  int statusReads = 0;
  bool freezeTransfers = false;
  Object? transfersError;
  @override
  Future<void> refreshTransfers() => transfersError != null
      ? Future.error(transfersError!)
      : freezeTransfers
      ? Future.value()
      : super.refreshTransfers();
  Completer<void>? deleteGate;
  Completer<void>? hubGate, profileGate;
  int hubCalls = 0, profileCalls = 0;
  @override
  Future<void> addHub(String address, String code, String name) async {
    final gate = hubGate;
    if (gate == null) return super.addHub(address, code, name);
    hubCalls++;
    await gate.future;
  }

  @override
  Future<void> updateProfile(
    String name, {
    String? avatar,
    bool appearance = false,
    String? preset,
    int? color,
  }) async {
    final gate = profileGate;
    if (gate == null) {
      return super.updateProfile(
        name,
        avatar: avatar,
        appearance: appearance,
        preset: preset,
        color: color,
      );
    }
    profileCalls++;
    await gate.future;
  }

  @override
  Future<void> deleteItem(InboxItem item) async {
    await deleteGate?.future;
    await super.deleteItem(item);
  }

  @override
  String copyStatus(InboxEntry entry) {
    statusReads++;
    return super.copyStatus(entry);
  }
}

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGMQaXr2H4QZYAwAUxQJ7UIG+7IAAAAASUVORK5CYII=',
);

class WidgetTestHarness {
  Future<void> openSettingsPage(WidgetTester tester, String page) async {
    if (find.byKey(const ValueKey('settings-panel')).evaluate().isEmpty) {
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
    }
    final destination = find.byKey(ValueKey('settings-page-$page'));
    if (destination.evaluate().isEmpty) {
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(destination);
    await tester.tap(destination);
    await tester.pumpAndSettle();
  }

  Future<void> closeSettings(WidgetTester tester) async {
    await tester.tap(find.byTooltip('关闭').last);
    await tester.pumpAndSettle();
  }

  Future<void> openGlobalSearch(WidgetTester tester) async {
    final search = find.byKey(const ValueKey('global-conversation-search'));
    if (search.evaluate().isEmpty) {
      await tester.tap(find.byTooltip('返回会话'));
      await tester.pumpAndSettle();
    }
    await tester.tap(search);
    await tester.pumpAndSettle();
  }

  WidgetTestHarness() {
    TestWidgetsFlutterBinding.ensureInitialized();
    setUp(_setUp);
    tearDown(_tearDown);
  }

  late Directory directory;
  late WidgetLan lan;
  late InboxController inbox;

  Future<void> _setUp() async {
    String? clipboard;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String?;
          }
          if (call.method == 'Clipboard.getData') {
            return clipboard == null ? null : {'text': clipboard};
          }
          if (call.method == 'Clipboard.hasStrings') {
            return {'value': clipboard?.isNotEmpty ?? false};
          }
          return null;
        });
    directory = await Directory.systemTemp.createTemp('lanflow-inbox-widget-');
    lan = WidgetLan(store: LocalStore(directory), receiveDirectory: directory)
      ..identity = Identity(
        '-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----',
        '',
      )
      ..name = '我的 Windows'
      ..ready = true
      ..addresses = ['192.168.5.8:53318'];
    inbox = WidgetInbox(lan: lan, store: InboxStore(directory));
    await inbox.start();
  }

  Future<void> _tearDown() async {
    await inbox.close();
    await lan.close();
    inbox.dispose();
    lan.dispose();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    for (var attempt = 0; ; attempt++) {
      try {
        await directory.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt >= 4) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lanflow/clipboard'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('lanflow/desktop'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  }

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1180, 780),
    TargetPlatform platform = TargetPlatform.windows,
    bool openMobileChat = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      LanFlowApp(controller: lan, inbox: inbox, platform: platform),
    );
    await tester.pumpAndSettle();
    if (size.width < 840 && openMobileChat) {
      await tester.tap(
        find.byKey(ValueKey('conversation-${inbox.conversationId}')),
      );
      await tester.pumpAndSettle();
    }
  }

  Future<void> waitFor(bool Function() condition) async {
    final elapsed = Stopwatch()..start();
    while (!condition()) {
      if (elapsed.elapsed > const Duration(seconds: 5)) {
        throw TestFailure('The expected asynchronous operation did not finish');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}
