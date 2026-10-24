import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/ui/chat/image_viewer.dart';
import 'package:lanflow/ui/shared/app_root.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      '$platform image taps and pan stay open while exposed background returns',
      (tester) async {
        final size = platform == TargetPlatform.windows
            ? const Size(1180, 780)
            : const Size(390, 844);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final file = File('${harness.directory.path}/portrait.png');
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawColor(Colors.green, BlendMode.src);
          final picture = recorder.endRecording();
          final image = await picture.toImage(100, 160);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await file.writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
            picture.dispose();
          }
        });
        await tester.pumpWidget(
          AppRoot(
            platform: platform,
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ImageViewer(
                      file: file,
                      name: 'portrait.png',
                      onMenu: (_) {},
                    ),
                  ),
                ),
                child: const Text('打开预览'),
              ),
            ),
          ),
        );
        await tester.runAsync(() async {
          await precacheImage(
            ResizeImage(
              FileImage(file),
              width: 3840,
              height: 3840,
              policy: ResizeImagePolicy.fit,
              allowUpscaling: false,
            ),
            tester.element(find.text('打开预览')),
          );
        });
        await tester.tap(find.text('打开预览'));
        await tester.pumpAndSettle();
        final photo = find.byKey(const ValueKey('preview-image'));
        await tester.tap(photo);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(find.byType(ImageViewer), findsOneWidget);
        if (platform == TargetPlatform.android) {
          expect(find.byTooltip('关闭图片'), findsNothing);
        }
        await tester.tap(photo);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(photo);
        await tester.pumpAndSettle();
        final viewer = tester.widget<InteractiveViewer>(
          find.byType(InteractiveViewer),
        );
        expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 2.5);
        await tester.drag(photo, const Offset(40, 40));
        await tester.pumpAndSettle();
        expect(find.byType(ImageViewer), findsOneWidget);
        await tester.tap(photo);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(find.byType(ImageViewer), findsOneWidget);
        final background = Offset(10, size.height * .3);
        expect(tester.getRect(photo).contains(background), isFalse);
        await tester.tapAt(background);
        await tester.tapAt(background);
        await tester.pumpAndSettle();
        expect(find.byType(ImageViewer), findsNothing);
        expect(find.text('打开预览'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'image viewer fills the screen, zooms and closes without focusing composer',
    (tester) async {
      final file = File('${harness.directory.path}/photo.png');
      await tester.runAsync(() async {
        await file.writeAsBytes(png);
      });
      final key = GlobalKey();
      tester.view.physicalSize = const Size(1180, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        AppRoot(
          platform: TargetPlatform.windows,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => RepaintBoundary(
                    key: key,
                    child: ImageViewer(
                      file: file,
                      name: 'photo.png',
                      onMenu: (_) {},
                    ),
                  ),
                ),
              ),
              child: const Text('预览图片'),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await precacheImage(
          ResizeImage(
            FileImage(file),
            width: 3840,
            height: 3840,
            policy: ResizeImagePolicy.fit,
            allowUpscaling: false,
          ),
          tester.element(find.text('预览图片')),
        );
      });
      await tester.tap(find.text('预览图片'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(ImageViewer)), const Size(1180, 780));
      await tester.tap(find.byTooltip('放大'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(
        tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        allOf(greaterThan(1), lessThan(1.25)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('适合窗口'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        1,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭图片'));
      await tester.pumpAndSettle();
      expect(find.text('预览图片'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('rapid image opens create one preview and Escape closes layers', (
    tester,
  ) async {
    var hidden = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('lanflow/desktop'), (
          call,
        ) async {
          if (call.method == 'hideToTray') hidden++;
          return null;
        });
    await tester.runAsync(() async {
      final file = File('${harness.directory.path}/preview.png');
      await file.writeAsBytes(png);
      await harness.inbox.addFile(file.path);
    });
    final item = harness.inbox.items.single.item;
    final bubble = find.byKey(ValueKey('inbox-item-${item.id}'));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final imageContext = tester.element(find.byType(ScaffoldMessenger));
    await tester.runAsync(() async {
      await precacheImage(
        ResizeImage(
          FileImage(harness.inbox.store.blob(item.digest)),
          width: ChatMetrics.imageWidthDesktop.toInt(),
          height: ChatMetrics.imageHeightDesktop.toInt(),
          policy: ResizeImagePolicy.fit,
          allowUpscaling: false,
        ),
        imageContext,
      ).timeout(const Duration(seconds: 10));
      await precacheImage(
        ResizeImage(
          FileImage(harness.inbox.store.blob(item.digest)),
          width: 3840,
          height: 3840,
          policy: ResizeImagePolicy.fit,
          allowUpscaling: false,
        ),
        imageContext,
      ).timeout(const Duration(seconds: 10));
    });
    await harness.mount(tester);
    final position = tester.getCenter(bubble);
    await tester.tapAt(position);
    await tester.tapAt(position);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsOneWidget);
    await tester.tap(find.byTooltip('图片操作'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-context-menu')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsOneWidget);
    expect(hidden, 0);
    final gate = Completer<void>();
    (harness.inbox as WidgetInbox).deleteGate = gate;
    await tester.tap(find.byTooltip('图片操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('desktop-menu-delete')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsNothing);
    expect(hidden, 0);
    gate.complete();
    for (var i = 0; i < 40 && harness.inbox.items.isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(harness.inbox.items, isEmpty);
    expect(find.byKey(const ValueKey('inbox-composer')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(hidden, Platform.isWindows ? 1 : 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
