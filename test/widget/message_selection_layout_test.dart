import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/chat/chat_history_view.dart';
import 'package:lanflow/ui/chat/message_selection.dart';
import 'package:lanflow/ui/chat/message_tile.dart';
import 'package:lanflow/ui/shared/app_root.dart';
import 'package:lanflow/ui/shared/profile_avatar.dart';

import '../support/widget_harness.dart';

Future<void> _previewFonts() async {
  for (final font in [
    ('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf'),
    ('Microsoft YaHei', r'C:\Windows\Fonts\msyh.ttc'),
    ('Microsoft YaHei UI', r'C:\Windows\Fonts\msyh.ttc'),
    ('Roboto', r'C:\Windows\Fonts\msyh.ttc'),
    ('MaterialIcons', 'build/unit_test_assets/fonts/MaterialIcons-Regular.otf'),
  ]) {
    final file = File(font.$2);
    if (await file.exists()) {
      await (FontLoader(
        font.$1,
      )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
    }
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey preview, String name) =>
    tester.runAsync(() async {
      final boundary =
          preview.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File('build/previews/$name.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });

void main() {
  final harness = WidgetTestHarness();

  InboxEntry entry(
    String id, {
    required bool local,
    required bool file,
    bool image = false,
    int minute = 0,
  }) => InboxEntry(
    minute + 1,
    InboxItem(
      id: id,
      originId: local ? harness.lan.identity.id : 'remote-device-000001',
      originName: local ? '我的电脑' : '我的手机',
      createdAt: DateTime.utc(2026, 10, 22, 8, minute),
      kind: image
          ? MessageKind.image
          : file
          ? MessageKind.file
          : MessageKind.text,
      text: file ? '' : '第一行内容\n第二行内容\n第三行内容\n第四行内容\n第五行内容\n第六行内容',
      name: file ? '用于检查多行文件名与选择框对齐的项目资料归档文件.zip' : '',
      size: file ? 7340032 : 0,
      digest: file ? 'a' * 64 : '',
    ),
  );

  Widget tile(
    InboxEntry item,
    MessageSelection selection, {
    required bool wide,
    required bool identity,
    required bool time,
    VoidCallback? open,
  }) => SelectableMessage(
    selection: selection,
    id: item.item.id,
    child: MessageTile(
      inbox: harness.inbox,
      entry: item,
      wide: wide,
      showTime: time,
      showIdentity: identity,
      showStatus: identity,
      onOpen: (_) async => open?.call(),
      onLink: (_) async {},
      onMenu: (_, _, {anchor}) async {},
      onStatus: () {},
      onSelectionChanged: (_) {},
    ),
  );

  for (final wide in [true, false]) {
    testWidgets(
      '${wide ? 'desktop' : 'mobile'} selection adds a separated avatar-height control only while active',
      (tester) async {
        final selection = MessageSelection();
        addTearDown(selection.dispose);
        tester.view.physicalSize = wide
            ? const Size(1180, 780)
            : const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(
          () => harness.inbox.store.blob('a' * 64).writeAsBytes(png),
        );
        var counter = 0;
        for (final local in [true, false]) {
          for (final kind in [
            MessageKind.text,
            MessageKind.file,
            MessageKind.image,
          ]) {
            for (final identity in [true, false]) {
              final item = entry(
                'aligned-message-${counter++}',
                local: local,
                file: kind != MessageKind.text,
                image: kind == MessageKind.image,
              );
              var opened = 0;
              await tester.pumpWidget(
                AppRoot(
                  platform: wide
                      ? TargetPlatform.windows
                      : TargetPlatform.android,
                  home: Scaffold(
                    body: SingleChildScrollView(
                      padding: const EdgeInsets.all(14),
                      child: tile(
                        item,
                        selection,
                        wide: wide,
                        identity: identity,
                        time: identity,
                        open: () => opened++,
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              final message = find.byKey(
                ValueKey('inbox-item-${item.item.id}'),
              );
              final avatarSlot = find.byKey(
                ValueKey('message-avatar-slot-${item.item.id}'),
              );
              final initialMessage = tester.getRect(message);
              final initialAvatar = tester.getRect(avatarSlot);
              final row = find.byKey(
                ValueKey('select-message-${item.item.id}'),
              );
              final initialRow = tester.getRect(row);
              if (local) {
                expect(initialAvatar.right, initialRow.right);
              } else {
                expect(
                  initialAvatar.left,
                  initialRow.left,
                  reason:
                      'Ordinary received messages must not reserve a selection gutter.',
                );
              }
              selection.begin(item.item.conversationId);
              await tester.pumpAndSettle();
              final checkbox = find.byKey(
                ValueKey('message-checkbox-${item.item.id}'),
              );
              expect(
                tester.widget<Checkbox>(checkbox).shape,
                isA<CircleBorder>(),
              );
              expect(
                tester.getCenter(checkbox).dy,
                closeTo(tester.getCenter(avatarSlot).dy, .01),
              );
              if (identity) {
                expect(
                  tester.getCenter(find.byType(ProfileAvatar)).dy,
                  closeTo(tester.getCenter(checkbox).dy, .01),
                );
              }
              final selectedMessage = tester.getRect(message);
              final selectedAvatar = tester.getRect(avatarSlot);
              if (local) {
                expect(selectedAvatar.right, initialAvatar.right);
                expect(
                  selectedMessage.right,
                  initialMessage.right,
                  reason:
                      'Outgoing messages stay aligned to the right while selection is active.',
                );
              } else {
                final avatarShift = selectedAvatar.left - initialAvatar.left;
                final bubbleShift = selectedMessage.left - initialMessage.left;
                expect(
                  avatarShift,
                  greaterThan(tester.getSize(checkbox).width),
                );
                expect(bubbleShift, closeTo(avatarShift, .01));
                final avatarToBubbleGap =
                    selectedMessage.left - selectedAvatar.right;
                final controlToAvatarGap =
                    selectedAvatar.left - tester.getRect(checkbox).right;
                expect(
                  controlToAvatarGap,
                  greaterThan(avatarToBubbleGap * 2),
                  reason:
                      'The selection control needs a distinct gap, not a slot touching the avatar.',
                );
              }
              expect(selectedAvatar.top, initialAvatar.top);
              expect(
                selectedMessage.width,
                lessThanOrEqualTo(initialMessage.width),
              );
              expect(
                tester.getCenter(checkbox).dy,
                lessThan(selectedMessage.bottom - 20),
              );
              await tester.tapAt(tester.getCenter(checkbox));
              await tester.pumpAndSettle();
              expect(selection.ids, {item.item.id});
              await tester.tapAt(tester.getCenter(message));
              await tester.pumpAndSettle();
              expect(selection.ids, isEmpty);
              expect(
                opened,
                0,
                reason: 'Selection taps must not open file cards.',
              );
              selection.setBusy(true);
              await tester.tapAt(tester.getCenter(checkbox));
              expect(selection.ids, isEmpty);
              selection.setBusy(false);
              selection.clear();
              await tester.pumpAndSettle();
              expect(tester.getRect(message), initialMessage);
              expect(tester.getRect(avatarSlot), initialAvatar);
              expect(tester.getRect(row), initialRow);
              expect(tester.takeException(), isNull);
            }
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '${wide ? 'desktop' : 'mobile'} history adds and removes selection spacing without resetting reading position',
      (tester) async {
        final selection = MessageSelection();
        final scroll = ScrollController();
        addTearDown(selection.dispose);
        addTearDown(scroll.dispose);
        tester.view.physicalSize = wide
            ? const Size(1000, 780)
            : const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final entries = List.generate(
          18,
          (index) => entry(
            'history-layout-$index',
            local: index % 4 < 2,
            file: index % 3 == 0,
            minute: 18 - index,
          ),
        );
        final rowKeys = <String, GlobalKey>{};
        final preview = GlobalKey();
        await tester.runAsync(_previewFonts);
        await tester.pumpWidget(
          RepaintBoundary(
            key: preview,
            child: AppRoot(
              platform: wide ? TargetPlatform.windows : TargetPlatform.android,
              home: Scaffold(
                body: ChatHistoryView(
                  entries: entries,
                  controller: scroll,
                  rowKeys: rowKeys,
                  wide: wide,
                  rowBuilder: (item, presentation) => tile(
                    item,
                    selection,
                    wide: wide,
                    identity: presentation.showIdentity,
                    time: presentation.showTime,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        scroll.jumpTo(430);
        await tester.pumpAndSettle();
        final viewport = tester.getRect(
          find.byKey(const ValueKey('self-chat-history')),
        );
        final anchor = entries.firstWhere((item) {
          if (item.item.originId == harness.lan.identity.id) return false;
          final finder = find.byKey(ValueKey('inbox-item-${item.item.id}'));
          if (finder.evaluate().isEmpty) return false;
          final rect = tester.getRect(finder);
          return rect.top >= viewport.top + 24 &&
              rect.bottom <= viewport.bottom - 24;
        });
        final finder = find.byKey(ValueKey('inbox-item-${anchor.item.id}'));
        final position = tester.getRect(finder);
        final avatar = find.byKey(
          ValueKey('message-avatar-slot-${anchor.item.id}'),
        );
        final avatarPosition = tester.getRect(avatar);
        final rowInset = ChatHistoryRowInsets.of(tester.element(finder));
        expect(
          avatarPosition.left,
          viewport.left + rowInset,
          reason:
              'The ordinary history starts its avatar at the normal inner margin.',
        );
        final previewName = 'selection-avatar-${wide ? 'desktop' : 'mobile'}';
        await _capture(tester, preview, '$previewName-normal');
        selection.begin(anchor.item.conversationId, anchor.item.id);
        await tester.pumpAndSettle();
        expect(scroll.offset, 430);
        expect(
          tester.getRect(find.byKey(const ValueKey('self-chat-history'))),
          viewport,
        );
        expect(tester.getRect(avatar).left, greaterThan(avatarPosition.left));
        expect(
          tester.getRect(finder).left - position.left,
          closeTo(tester.getRect(avatar).left - avatarPosition.left, .01),
        );
        final checkbox = find.byKey(
          ValueKey('message-checkbox-${anchor.item.id}'),
        );
        expect(
          tester.getRect(checkbox).right,
          lessThan(tester.getRect(avatar).left),
        );
        expect(
          tester.getCenter(checkbox).dy,
          closeTo(tester.getCenter(avatar).dy, .01),
        );
        final selectedRow = find.byKey(
          ValueKey('select-message-${anchor.item.id}'),
        );
        expect(tester.getRect(selectedRow).left, viewport.left);
        expect(tester.getRect(selectedRow).right, viewport.right);
        final fill = tester.widget<Material>(
          find.ancestor(of: selectedRow, matching: find.byType(Material)).first,
        );
        expect(fill.borderRadius, isNull);
        await _capture(tester, preview, '$previewName-selected');
        await _capture(tester, preview, previewName);
        selection.clear();
        await tester.pumpAndSettle();
        expect(scroll.offset, 430);
        expect(tester.getRect(avatar).left, avatarPosition.left);
        expect(tester.getRect(finder).left, position.left);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'compact selection actions retain 48px height and scroll to every action',
    (tester) async {
      final selection = MessageSelection()
        ..begin('conversation-0001', 'message-00000001');
      addTearDown(selection.dispose);
      var deleted = 0;
      await tester.pumpWidget(
        AppRoot(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 260,
                child: MessageSelectionBar(
                  selection: selection,
                  compact: true,
                  onAll: () {},
                  onDelete: () => deleted++,
                  onExport: () {},
                  onFavorite: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bar = find.byType(MessageSelectionBar);
      expect(tester.getSize(bar).height, 48);
      final delete = find.byKey(const ValueKey('delete-selected-messages'));
      await tester.ensureVisible(delete);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(delete).right,
        lessThanOrEqualTo(tester.getRect(bar).right),
      );
      await tester.tap(delete);
      expect(deleted, 1);
      expect(tester.getSize(bar).height, 48);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final spec in [
    ('desktop', const Size(700, 150), 1.0),
    ('mobile', const Size(390, 60), 1.0),
    ('mobile-large', const Size(320, 48), 1.5),
  ]) {
    testWidgets(
      '${spec.$1} action panel preserves its editor bounds and keeps cancel visible',
      (tester) async {
        final selection = MessageSelection()
          ..begin('conversation-0001', 'message-00000001');
        addTearDown(selection.dispose);
        tester.platformDispatcher.textScaleFactorTestValue = spec.$3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final invoked = <String>[];
        final preview = GlobalKey();
        await tester.runAsync(_previewFonts);
        await tester.pumpWidget(
          RepaintBoundary(
            key: preview,
            child: AppRoot(
              platform: spec.$1 == 'desktop'
                  ? TargetPlatform.windows
                  : TargetPlatform.android,
              home: Scaffold(
                body: Center(
                  child: Container(
                    width: spec.$2.width,
                    height: spec.$2.height,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                      color: Colors.white,
                    ),
                    child: MessageSelectionBar(
                      selection: selection,
                      panel: true,
                      onAll: () => invoked.add('all'),
                      onDelete: () => invoked.add('delete'),
                      onExport: () => invoked.add('export'),
                      onFavorite: () => invoked.add('favorite'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final panel = find.byType(MessageSelectionBar);
        expect(
          tester.getSize(panel),
          Size(spec.$2.width - 2, spec.$2.height - 2),
        );
        final cancel = find.byTooltip('取消多选');
        final cancelRect = tester.getRect(cancel);
        final first = find.byKey(const ValueKey('selection-panel-all'));
        final favorite = find.byKey(const ValueKey('selection-panel-favorite'));
        final export = find.byKey(const ValueKey('selection-panel-export'));
        final delete = find.byKey(const ValueKey('delete-selected-messages'));
        for (final action in [favorite, export, delete]) {
          expect(tester.getSize(action), tester.getSize(first));
        }
        final icon = find.descendant(of: favorite, matching: find.byType(Icon));
        final label = find.descendant(of: favorite, matching: find.text('收藏'));
        expect(tester.getCenter(icon).dy, lessThan(tester.getCenter(label).dy));
        await tester.ensureVisible(delete);
        await tester.pumpAndSettle();
        expect(tester.getRect(cancel), cancelRect);
        await tester.tap(delete);
        expect(invoked, ['delete']);
        expect(tester.getSize(panel).height, spec.$2.height - 2);
        await tester.runAsync(() async {
          final image =
              await (preview.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'build/previews/selection-panel-${spec.$1}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.tap(cancel);
        expect(selection.active, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
