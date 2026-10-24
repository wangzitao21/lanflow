import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/ui/chat/image_viewer.dart';

void main() {
  testWidgets(
    'zooming a long screenshot loads readable detail with bounded decoded memory',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('lanflow-long-preview-'),
      ))!;
      try {
        final file = File('${root.path}/long.png');
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder)
            ..drawColor(Colors.white, BlendMode.src);
          for (var y = 0.0; y < 20000; y += 25) {
            canvas.drawRect(
              Rect.fromLTWH(20, y, 1100, 2),
              Paint()..color = Colors.black,
            );
          }
          final picture = recorder.endRecording();
          final original = await picture.toImage(1200, 20000);
          final data = await original.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await file.writeAsBytes(data!.buffer.asUint8List());
          original.dispose();
          picture.dispose();
        });
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.runAsync(() async {
          for (final side in [3840, 16384]) {
            await precacheImage(
              ResizeImage(
                FileImage(file),
                width: side,
                height: side,
                policy: ResizeImagePolicy.fit,
                allowUpscaling: false,
              ),
              tester.element(find.byType(ScaffoldMessenger)),
            );
          }
        });
        await tester.pumpWidget(
          MaterialApp(
            home: ImageViewer(file: file, name: 'long.png', onMenu: (_) {}),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        final viewer = tester.widget<InteractiveViewer>(
          find.byType(InteractiveViewer),
        );
        expect(viewer.maxScale, greaterThan(6));
        viewer.transformationController!.value = Matrix4.identity()
          ..scaleByDouble(30, 30, 1, 1);
        await tester.pump(const Duration(milliseconds: 150));
        final provider = tester
            .widget<Image>(find.byKey(const ValueKey('preview-image')))
            .image;
        expect((provider as ResizeImage).height, greaterThan(3840));
        await tester.runAsync(() async {
          final decoded = Completer<Size>();
          final stream = provider.resolve(ImageConfiguration.empty);
          final listener = ImageStreamListener((info, _) {
            if (!decoded.isCompleted) {
              decoded.complete(
                Size(info.image.width.toDouble(), info.image.height.toDouble()),
              );
            }
            info.dispose();
          }, onError: decoded.completeError);
          stream.addListener(listener);
          try {
            final size = await decoded.future.timeout(
              const Duration(seconds: 20),
            );
            expect(size.width, greaterThan(900));
            expect(
              size.width * size.height,
              lessThanOrEqualTo(16 * 1024 * 1024),
            );
          } finally {
            stream.removeListener(listener);
          }
        });
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final boundary = await Directory.systemTemp.resolveSymbolicLinks();
          expect(
            (await root.resolveSymbolicLinks()).startsWith(
              '$boundary${Platform.pathSeparator}lanflow-long-preview-',
            ),
            isTrue,
          );
          await root.delete(recursive: true);
        });
      }
    },
  );
}
