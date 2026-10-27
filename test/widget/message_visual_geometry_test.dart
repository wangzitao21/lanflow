import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/chat/chat_history_view.dart';
import 'package:lanflow/ui/chat/message_bubble.dart';
import 'package:lanflow/ui/chat/message_presentation.dart';
import 'package:lanflow/ui/chat/message_selection.dart';
import 'package:lanflow/ui/chat/message_tile.dart';
import 'package:lanflow/ui/shared/app_root.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/attachment_thumbnail.dart';
import 'package:lanflow/ui/shared/profile_avatar.dart';

import '../support/widget_harness.dart';

Future<File> _fixture(
  Directory directory,
  String name,
  int width,
  int height,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFFF9FBFD),
  );
  if (height > width * 2) {
    canvas.drawRect(
      Rect.fromLTWH(32, 36, width - 64.0, 28),
      Paint()..color = const Color(0xFF2E546D),
    );
    for (var y = 100.0; y < height - 40; y += 38) {
      canvas.drawRect(
        Rect.fromLTWH(32, y, width - 64 - (y.toInt() % 3) * 35.0, 9),
        Paint()..color = const Color(0xFF7C878B),
      );
    }
  } else {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height * .58),
      Paint()..color = const Color(0xFFA8CFDF),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, height * .58, width.toDouble(), height * .42),
      Paint()..color = const Color(0xFF78A889),
    );
    canvas.drawCircle(
      Offset(width * .74, height * .25),
      height * .1,
      Paint()..color = const Color(0xFFFFD66B),
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return File('${directory.path}/$name.png')
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<void> _loadImages(WidgetTester tester) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    final expected = find.byType(Image).evaluate().length;
    final decoded = tester
        .widgetList<RawImage>(find.byType(RawImage))
        .where((image) => image.image != null)
        .length;
    final failed = find.byIcon(Icons.broken_image_outlined).evaluate().length;
    if (decoded + failed >= expected) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Images did not finish loading');
}

Future<void> _fonts() async {
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

void main() {
  final harness = WidgetTestHarness();

  Widget row(
    InboxEntry entry, {
    required bool wide,
    required MessagePresentation presentation,
    Future<void> Function(String)? onLink,
  }) => MessageTile(
    inbox: harness.inbox,
    entry: entry,
    wide: wide,
    showTime: presentation.showTime,
    showIdentity: presentation.showIdentity,
    showStatus: presentation.showStatus,
    onOpen: (_) async {},
    onLink: onLink ?? (_) async {},
    onMenu: (_, _, {anchor}) async {},
    onStatus: () {},
    onSelectionChanged: (_) {},
  );

  for (final wide in [true, false]) {
    testWidgets(
      '${wide ? 'desktop' : 'phone'} images use their real landscape, square and long-image bounds',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetDevicePixelRatio);
        for (final dimensions in [
          (900, 600),
          (700, 700),
          (400, 1160),
          (300, 1800),
        ]) {
          late File file;
          await tester.runAsync(() async {
            file = await _fixture(
              harness.directory,
              'ratio-${dimensions.$1}-${dimensions.$2}',
              dimensions.$1,
              dimensions.$2,
            );
          });
          final maxWidth = wide ? 300.0 : 260.0;
          final maxHeight = wide ? 320.0 : 300.0;
          await tester.pumpWidget(
            AppRoot(
              home: Scaffold(
                body: Center(
                  child: AttachmentThumbnail(
                    file: file,
                    maxWidth: maxWidth,
                    maxHeight: maxHeight,
                  ),
                ),
              ),
            ),
          );
          await _loadImages(tester);
          final thumbnail = find.byType(AttachmentThumbnail);
          final raw = find.descendant(
            of: thumbnail,
            matching: find.byType(RawImage),
          );
          expect(raw, findsOneWidget);
          expect(tester.widget<RawImage>(raw).image, isNotNull);
          final size = tester.getSize(thumbnail);
          expect(
            size.width / size.height,
            closeTo(dimensions.$1 / dimensions.$2, .005),
          );
          expect(size.width, lessThanOrEqualTo(maxWidth));
          expect(size.height, lessThanOrEqualTo(maxHeight));
          expect(
            tester.getRect(raw),
            tester.getRect(thumbnail),
            reason: 'A loaded preview must not retain a padded image frame.',
          );
          if (dimensions.$2 > dimensions.$1 * 2) {
            expect(size.height, closeTo(maxHeight, 1));
            expect(size.width, lessThan(size.height / 2));
            expect(size.height, greaterThan(250));
          }
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'file and image bubbles point towards their avatars without padding the image',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      late Map<String, dynamic> imported;
      await tester.runAsync(() async {
        final file = await _fixture(harness.directory, 'media-tail', 200, 300);
        imported = await harness.inbox.store.importFile(
          file.path,
          name: 'preview.png',
          kind: 'image',
        );
      });
      for (final local in [false, true]) {
        for (final kind in [MessageKind.image, MessageKind.file]) {
          final entry = InboxEntry(
            1,
            InboxItem(
              id: 'media-arrow-${local.toString()}-${kind.name}',
              originId: local ? harness.lan.identity.id : 'remote-device-00001',
              originName: '我的手机',
              createdAt: DateTime.utc(2026, 10, 22),
              kind: kind,
              name: kind == MessageKind.image ? 'preview.png' : '研究资料.zip',
              size: imported['size'] as int,
              digest: imported['sha256'] as String,
            ),
          );
          await tester.pumpWidget(
            AppRoot(
              home: Scaffold(
                body: Center(
                  child: row(
                    entry,
                    wide: true,
                    presentation: const MessagePresentation(
                      showTime: false,
                      showIdentity: true,
                      showStatus: true,
                    ),
                  ),
                ),
              ),
            ),
          );
          await _loadImages(tester);
          final bubble = find.byKey(ValueKey('media-bubble-${entry.item.id}'));
          final widget = tester.widget<MessageBubble>(bubble);
          final size = tester.getSize(bubble);
          final bounds = tester.getRect(bubble);
          final badge = tester.getRect(
            find.byKey(ValueKey('sync-badge-${entry.item.id}')),
          );
          expect(
            badge.center.dx,
            closeTo(
              bounds.right - (local ? ChatMetrics.bubbleTailWidth : 0),
              .1,
            ),
          );
          expect(badge.center.dy, closeTo(bounds.bottom, .1));
          expect(widget.outgoing, local);
          final shape = MessageBubbleBorder(
            outgoing: local,
            tailOffset: local ? 20 : 12,
          );
          final path = shape.getOuterPath(Offset.zero & size);
          final edge = local ? size.width - 1 : 1.0;
          expect(path.contains(Offset(edge, local ? 20 : 12)), isTrue);
          expect(path.contains(Offset(edge, 40)), isFalse);
          if (kind == MessageKind.image) {
            final image = tester.getSize(find.byType(AttachmentThumbnail));
            expect(size.width - image.width, ChatMetrics.bubbleTailWidth);
            expect(size.height, image.height);
            expect(image.width / image.height, closeTo(2 / 3, .005));
          }
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'missing thumbnails remain usable within small collection bounds',
    (tester) async {
      var opened = false;
      await tester.pumpWidget(
        AppRoot(
          home: Scaffold(
            body: Center(
              child: AttachmentThumbnail(
                file: File('${harness.directory.path}/missing.png'),
                maxWidth: 64,
                maxHeight: 48,
                onTap: () => opened = true,
              ),
            ),
          ),
        ),
      );
      await _loadImages(tester);
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(
        tester.getSize(find.byType(AttachmentThumbnail)),
        const Size(64, 48),
      );
      await tester.tap(find.byType(AttachmentThumbnail));
      expect(opened, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'consecutive messages retain every avatar, remote identity and outgoing status',
    (tester) async {
      final entries = List.generate(
        4,
        (index) => InboxEntry(
          index + 1,
          InboxItem(
            id: 'identity-message-$index',
            originId: index < 2
                ? harness.lan.identity.id
                : 'remote-device-00001',
            originName: index < 2 ? '本机' : '另一台设备',
            createdAt: DateTime.utc(2026, 10, 22, 8, 0, 4 - index),
            kind: MessageKind.text,
            text: '连续消息 $index',
          ),
        ),
      );
      for (var index = 0; index < entries.length; index++) {
        final presentation = MessagePresentation.at(entries, index);
        expect(presentation.showIdentity, isTrue);
        expect(presentation.showStatus, isTrue);
      }
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        AppRoot(
          home: Scaffold(
            body: ChatHistoryView(
              entries: entries,
              controller: scroll,
              rowKeys: {},
              wide: true,
              rowBuilder: (entry, presentation) =>
                  row(entry, wide: true, presentation: presentation),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProfileAvatar), findsNWidgets(4));
      expect(find.text('另一台设备'), findsNWidgets(2));
      for (final entry in entries) {
        expect(
          find.byKey(ValueKey('copy-status-${entry.item.id}')),
          findsOneWidget,
        );
        final content = tester.getRect(
          find.byKey(ValueKey('message-badge-content-${entry.item.id}')),
        );
        final circle = tester.getRect(
          find.byKey(ValueKey('sync-badge-${entry.item.id}')),
        );
        final local = entry.item.originId == harness.lan.identity.id;
        expect(
          circle.center.dx,
          closeTo(
            content.right - (local ? ChatMetrics.bubbleTailWidth : 0),
            .1,
          ),
        );
        expect(circle.center.dy, closeTo(content.bottom, .1));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'text bubble padding uses I-beam while links keep their clickable cursor and action',
    (tester) async {
      const text = 'alpha beta https://example.com/notes omega';
      String? opened;
      final entry = InboxEntry(
        1,
        InboxItem(
          id: 'cursor-message-0001',
          originId: harness.lan.identity.id,
          originName: '本机',
          createdAt: DateTime.utc(2026, 10, 22),
          kind: MessageKind.text,
          text: text,
        ),
      );
      await tester.pumpWidget(
        AppRoot(
          platform: TargetPlatform.windows,
          home: Scaffold(
            body: row(
              entry,
              wide: true,
              presentation: const MessagePresentation(
                showTime: false,
                showIdentity: true,
                showStatus: true,
              ),
              onLink: (value) async => opened = value,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bubble = find.byType(MessageBubble);
      final rich = find.descendant(of: bubble, matching: find.byType(RichText));
      final paragraph = tester.renderObject<RenderParagraph>(rich.first);
      Offset at(int offset) => paragraph.localToGlobal(
        paragraph
            .getBoxesForSelection(
              TextSelection(baseOffset: offset, extentOffset: offset + 2),
            )
            .first
            .toRect()
            .center,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      await mouse.moveTo(at(1));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.text,
      );
      await mouse.moveTo(tester.getRect(bubble).topLeft + const Offset(12, 5));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.text,
      );
      await mouse.moveTo(at(text.indexOf('https')));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );
      await mouse.down(at(text.indexOf('https')));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(opened, 'https://example.com/notes');
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'render left and right bubbles and proportional images in both themes and form factors',
    (tester) async {
      final pictures = <String, Map<String, dynamic>>{};
      await tester.runAsync(() async {
        await _fonts();
        for (final spec in [
          ('landscape', 900, 600),
          ('square', 700, 700),
          ('long', 400, 1160),
        ]) {
          final file = await _fixture(
            harness.directory,
            spec.$1,
            spec.$2,
            spec.$3,
          );
          pictures[spec.$1] = await harness.inbox.store.importFile(
            file.path,
            name: '${spec.$1}.png',
            kind: 'image',
          );
        }
      });
      InboxEntry image(String name, bool local, int index) => InboxEntry(
        index,
        InboxItem(
          id: 'preview-image-$name',
          originId: local ? harness.lan.identity.id : 'remote-device-00001',
          originName: local ? '本机' : '我的手机',
          createdAt: DateTime.utc(2026, 10, 22, 8, 0, index),
          kind: MessageKind.image,
          name: '$name.png',
          size: pictures[name]!['size'] as int,
          digest: pictures[name]!['sha256'] as String,
        ),
      );
      InboxEntry text(String value, bool local, int index) => InboxEntry(
        index,
        InboxItem(
          id: 'preview-text-$index',
          originId: local ? harness.lan.identity.id : 'remote-device-00001',
          originName: local ? '本机' : '我的手机',
          createdAt: DateTime.utc(2026, 10, 22, 8, 0, index),
          kind: MessageKind.text,
          text: value,
        ),
      );
      final entries = [
        image('square', false, 7),
        image('long', true, 6),
        image('landscape', false, 5),
        text('好，我稍后看。', false, 4),
        text('这张长图现在按原比例显示。', true, 3),
        text('第二条消息也保留头像。', true, 2),
        text('资料在 https://example.com/notes', false, 1),
      ];
      final selection = MessageSelection();
      addTearDown(selection.dispose);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final wide in [true, false]) {
        tester.view.physicalSize = wide
            ? const Size(1000, 1450)
            : const Size(390, 1450);
        for (final dark in [false, true]) {
          final scroll = ScrollController();
          final preview = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: preview,
              child: AppRoot(
                platform: wide
                    ? TargetPlatform.windows
                    : TargetPlatform.android,
                themeMode: dark ? ThemeMode.dark : ThemeMode.light,
                home: Scaffold(
                  body: ChatHistoryView(
                    entries: entries,
                    controller: scroll,
                    rowKeys: {},
                    wide: wide,
                    rowBuilder: (entry, presentation) => SelectableMessage(
                      selection: selection,
                      id: entry.item.id,
                      child: row(entry, wide: wide, presentation: presentation),
                    ),
                  ),
                ),
              ),
            ),
          );
          await _loadImages(tester);
          expect(find.byType(ProfileAvatar), findsNWidgets(entries.length));
          for (final entry in entries.where((entry) => entry.item.isFile)) {
            final thumbnail = find.byKey(
              ValueKey('image-thumbnail-${entry.item.id}'),
            );
            expect(
              find.ancestor(
                of: thumbnail,
                matching: find.byType(MessageBubble),
              ),
              findsOneWidget,
            );
          }
          await tester.runAsync(() async {
            final image =
                await (preview.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            try {
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final output = File(
                'build/previews/message-geometry-${wide ? 'desktop' : 'phone'}-${dark ? 'dark' : 'light'}.png',
              );
              await output.parent.create(recursive: true);
              await output.writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          scroll.dispose();
        }
      }
    },
  );
}
