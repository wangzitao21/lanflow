import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';

import 'icon_artwork.dart';

const selectedArtwork = 1;

Future<Uint8List> render(int size) async {
  final recorder = ui.PictureRecorder();
  paintIcon(ui.Canvas(recorder), size.toDouble(), iconDesigns[selectedArtwork]);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  final bytes = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!.buffer.asUint8List();
  image.dispose();
  picture.dispose();
  return bytes;
}

void main() {
  testWidgets('generate matching platform icons from one vector', (
    tester,
  ) async {
    await tester.runAsync(() async {
      const res = 'platforms/android/app/src/main/res';
      for (final pair in [
        ('mdpi', 48),
        ('hdpi', 72),
        ('xhdpi', 96),
        ('xxhdpi', 144),
        ('xxxhdpi', 192),
      ]) {
        await File(
          '$res/mipmap-${pair.$1}/ic_launcher.png',
        ).writeAsBytes(await render(pair.$2));
      }
      final icons = [
        for (final size in [16, 24, 32, 48, 64, 128, 256])
          (size, await render(size)),
      ];
      final header = ByteData(6 + icons.length * 16)
        ..setUint16(2, 1, Endian.little)
        ..setUint16(4, icons.length, Endian.little);
      var offset = header.lengthInBytes;
      for (var i = 0; i < icons.length; i++) {
        final (size, data) = icons[i];
        final p = 6 + i * 16;
        header
          ..setUint8(p, size == 256 ? 0 : size)
          ..setUint8(p + 1, size == 256 ? 0 : size)
          ..setUint16(p + 4, 1, Endian.little)
          ..setUint16(p + 6, 32, Endian.little)
          ..setUint32(p + 8, data.length, Endian.little)
          ..setUint32(p + 12, offset, Endian.little);
        offset += data.length;
      }
      await File(
        'platforms/windows/runner/resources/app_icon.ico',
      ).writeAsBytes([
        ...header.buffer.asUint8List(),
        for (final entry in icons) ...entry.$2,
      ]);
      await Directory('$res/mipmap-anydpi-v26').create(recursive: true);
      final artwork = iconDesigns[selectedArtwork];
      String hex(int color) =>
          '#${color.toRadixString(16).substring(2).toUpperCase()}';
      String vector({bool monochrome = false}) =>
          '''<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp" android:viewportWidth="108" android:viewportHeight="108">
    <group android:pivotX="54" android:pivotY="54" android:scaleX="0.9" android:scaleY="0.9">
      ${artwork.strokes.map((stroke) => '<path android:strokeColor="${monochrome ? '#FFFFFF' : hex(stroke.color)}" android:strokeWidth="${stroke.width}" android:strokeLineCap="round" android:strokeLineJoin="round" android:pathData="${stroke.data}" />').join('\n      ')}
    </group>
</vector>
''';
      await File('$res/drawable/lanflow_icon.xml').writeAsString(vector());
      await File(
        '$res/drawable/lanflow_icon_monochrome.xml',
      ).writeAsString(vector(monochrome: true));
      await File('$res/drawable/lanflow_icon_background.xml').writeAsString(
        '''<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt" android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <path android:pathData="M0,0 H108 V108 H0 Z">
      <aapt:attr name="android:fillColor">
        <gradient android:startX="12" android:startY="4" android:endX="94" android:endY="104" android:type="linear">
          <item android:offset="0" android:color="${hex(artwork.top)}" />
          <item android:offset="1" android:color="${hex(artwork.bottom)}" />
        </gradient>
      </aapt:attr>
    </path>
</vector>
''',
      );
      await File('$res/values/icon_colors.xml').writeAsString(
        '<resources><color name="lanflow_icon_background">${hex(artwork.bottom)}</color></resources>\n',
      );
      await File('$res/mipmap-anydpi-v26/ic_launcher.xml').writeAsString(
        '''<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/lanflow_icon_background" />
    <foreground android:drawable="@drawable/lanflow_icon" />
    <monochrome android:drawable="@drawable/lanflow_icon_monochrome" />
</adaptive-icon>
''',
      );
      await File(
        'build/lanflow-icon-preview.png',
      ).writeAsBytes(await render(128));
      await File('build/lanflow-icon.png').writeAsBytes(await render(512));
    });
  });
}
