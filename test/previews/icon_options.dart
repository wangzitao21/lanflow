import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../scripts/icon_artwork.dart';

void main() {
  testWidgets('render three application icon directions at real sizes', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await (FontLoader('IconLabel')..addFont(
            File(
              r'C:\Windows\Fonts\msyh.ttc',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawColor(const ui.Color(0xFFF4F5F3), ui.BlendMode.src);
      for (var i = 0; i < iconDesigns.length; i++) {
        final x = i * 280.0;
        canvas.save();
        canvas.translate(x + 54, 30);
        paintIcon(canvas, 172, iconDesigns[i]);
        canvas.restore();
        final builder =
            ui.ParagraphBuilder(
                ui.ParagraphStyle(
                  fontFamily: 'IconLabel',
                  fontSize: 18,
                  textAlign: ui.TextAlign.center,
                ),
              )
              ..pushStyle(ui.TextStyle(color: const ui.Color(0xFF283E39)))
              ..addText(iconDesigns[i].name);
        final text = builder.build()
          ..layout(const ui.ParagraphConstraints(width: 280));
        canvas.drawParagraph(text, ui.Offset(x, 220));
        text.dispose();
        for (final pair in [(90.0, 40.0), (150.0, 24.0)]) {
          canvas.save();
          canvas.translate(x + pair.$1, 270);
          paintIcon(canvas, pair.$2, iconDesigns[i]);
          canvas.restore();
        }
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(840, 340);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        'build/icon-options.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
      picture.dispose();
    });
  });
}
