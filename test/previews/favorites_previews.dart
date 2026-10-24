import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/app.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';

import '../support/favorite_ui_harness.dart';
import '../support/widget_harness.dart';

Future<void> _loadFonts() async {
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

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) =>
    tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = await Directory(
          'build/previews/favorites-controls',
        ).create(recursive: true);
        await File(
          '${output.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });

void main() {
  final harness = WidgetTestHarness();
  testWidgets(
    'render independent favorites cards and inline details in both languages',
    (tester) async {
      final inbox = await installFavoriteUiInbox(tester, harness);
      late FavoriteEntry note, landscape;
      await tester.runAsync(() async {
        await _loadFonts();
        final time = DateTime.utc(2026, 10, 22, 10);
        note = inbox.capture(
          InboxItem(
            id: randomToken(18),
            originId: 'a' * 32,
            originName: 'My Windows',
            createdAt: time.subtract(const Duration(days: 2)),
            kind: MessageKind.text,
            text:
                '设计备忘：把重要信息留在手边。\n收藏保留一份独立副本，原会话删除后仍可查看和导出。\nhttps://example.com/project-notes',
          ),
          savedAt: time,
        );
        final image = await favoriteImageFixture(
          harness.directory,
          '山色与日光.png',
          640,
          360,
        );
        landscape = inbox.capture(
          InboxItem(
            id: randomToken(18),
            originId: 'b' * 32,
            originName: 'My Android',
            createdAt: time,
            kind: MessageKind.image,
            name: '山色与日光.png',
            size: await image.length(),
            digest: 'b' * 64,
          ),
          savedAt: time.subtract(const Duration(minutes: 8)),
        );
        inbox.attachmentFiles[landscape.id] = image;
        final document = await File(
          '${harness.directory.path}/研究资料.pdf',
        ).writeAsString('Preview fixture');
        final file = inbox.capture(
          InboxItem(
            id: randomToken(18),
            originId: 'a' * 32,
            originName: 'My Windows',
            createdAt: time,
            kind: MessageKind.file,
            name: '研究资料与参考文献.pdf',
            size: 2457600,
            digest: 'c' * 64,
          ),
          savedAt: time.subtract(const Duration(minutes: 15)),
        );
        inbox.attachmentFiles[file.id] = document;
        final tallImage = await favoriteImageFixture(
          harness.directory,
          '竖幅灵感.png',
          360,
          1044,
        );
        final portrait = inbox.capture(
          InboxItem(
            id: randomToken(18),
            originId: 'b' * 32,
            originName: 'My Android',
            createdAt: time,
            kind: MessageKind.image,
            name: '竖幅灵感.png',
            size: await tallImage.length(),
            digest: 'd' * 64,
          ),
          savedAt: time.subtract(const Duration(minutes: 20)),
        );
        inbox.attachmentFiles[portrait.id] = tallImage;
        for (final (index, text) in [
          (0, '下次试试：\n把常用资料分组收藏，留出更多专注的时间。'),
          (1, 'Less, but better.'),
          (2, '周末备忘\n• 整理照片\n• 记录新的灵感\n• 和朋友去看展'),
          (
            3,
            'A few ideas worth keeping close.\nSmall steps make a meaningful difference.',
          ),
          (4, '简洁的界面，让内容自己说话。'),
        ]) {
          inbox.capture(
            InboxItem(
              id: randomToken(18),
              originId: 'c' * 32,
              originName: index.isEven ? 'My Android' : 'My Windows',
              createdAt: time,
              kind: MessageKind.text,
              text: text,
            ),
            savedAt: time.subtract(Duration(minutes: 30 + index)),
          );
        }
      });
      final boundary = GlobalKey();
      await inbox.setFavoritesPinned([note.id, landscape.id], true);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final spec in [
        ('zh-desktop', 'zh', const Size(1180, 780), 1.0),
        ('en-desktop', 'en', const Size(1180, 780), 1.0),
        ('zh-phone', 'zh', const Size(390, 844), 1.0),
        ('en-small-large', 'en', const Size(320, 720), 1.3),
      ]) {
        final desktop = spec.$3.width >= 840;
        await inbox.setFavoritePreferences(
          inbox.favoritePreferences.copyWith(
            layout: 'masonry',
            filter: 'all',
            sort: 'newest',
            onlyPinned: false,
          ),
        );
        await tester.runAsync(() => inbox.setLanguage(spec.$2));
        tester.view.physicalSize = spec.$3;
        tester.platformDispatcher.textScaleFactorTestValue = spec.$4;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: LanFlowApp(
              controller: harness.lan,
              inbox: inbox,
              platform: desktop
                  ? TargetPlatform.windows
                  : TargetPlatform.android,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(
            ValueKey(
              desktop ? 'desktop-nav-favorites' : 'mobile-nav-favorites',
            ),
          ),
        );
        await settleFavoriteImages(tester);
        await _capture(tester, boundary, '${spec.$1}-cards');
        await tester.tap(find.byKey(const ValueKey('favorites-select-mode')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('favorites-select-all')));
        await tester.pumpAndSettle();
        await _capture(tester, boundary, '${spec.$1}-selected');
        await tester.tap(find.byKey(const ValueKey('favorites-select-mode')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(ValueKey('favorite-${note.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('favorite-${note.id}')));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(
          find.byKey(ValueKey('favorite-detail-${note.id}')),
          findsOneWidget,
        );
        await _capture(tester, boundary, '${spec.$1}-text-detail');
        await tester.tap(find.byKey(const ValueKey('favorite-detail-back')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(ValueKey('favorite-${landscape.id}')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('favorite-${landscape.id}')));
        await settleFavoriteImages(tester);
        expect(
          find.byKey(ValueKey('favorite-detail-${landscape.id}')),
          findsOneWidget,
        );
        await _capture(tester, boundary, '${spec.$1}-image-detail');
        await tester.tap(find.byKey(const ValueKey('favorite-detail-back')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('favorites-view-list')));
        await settleFavoriteImages(tester);
        await _capture(tester, boundary, '${spec.$1}-list');
        await tester.tap(find.byKey(const ValueKey('favorites-filter-menu')));
        await tester.pumpAndSettle();
        await _capture(tester, boundary, '${spec.$1}-filters');
        await tester.tap(find.byKey(const ValueKey('favorites-filter-image')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('favorites-sort-menu')));
        await tester.pumpAndSettle();
        await _capture(tester, boundary, '${spec.$1}-sort');
        await tester.tap(find.byKey(const ValueKey('favorites-sort-oldest')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
}
