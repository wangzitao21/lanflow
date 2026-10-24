import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, int> _usedIcons() {
  final sdkIcons = File(
    Platform.environment['LANFLOW_MATERIAL_ICONS_SOURCE'] ??
        '.tooling/flutter/packages/flutter/lib/src/material/icons.dart',
  ).readAsStringSync();
  final definitions = {
    for (final match in RegExp(
      r'static const IconData\s+(\w+)\s*=\s*IconData\(\s*(0x[\da-fA-F]+)',
    ).allMatches(sdkIcons))
      match[1]!: int.parse(match[2]!.substring(2), radix: 16),
  };
  final used = <String, int>{};
  for (final file in Directory(
    'lib',
  ).listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart')) continue;
    for (final match in RegExp(
      r'\bIcons\.(\w+)',
    ).allMatches(file.readAsStringSync())) {
      final name = match[1]!;
      final point = definitions[name];
      expect(
        point,
        isNotNull,
        reason: 'Cannot resolve application icon $name.',
      );
      used[name] = point!;
    }
  }
  expect(used, isNotEmpty);
  return used;
}

Set<int> _fontCodepoints(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final tables = data.getUint16(4);
  int? cmap;
  for (var offset = 12; offset < 12 + tables * 16; offset += 16) {
    if (data.getUint32(offset) == 0x636d6170) cmap = data.getUint32(offset + 8);
  }
  expect(cmap, isNotNull, reason: 'Release icon font has no cmap.');
  final base = cmap!;
  final result = <int>{};
  final records = data.getUint16(base + 2);
  for (var offset = base + 4; offset < base + 4 + records * 8; offset += 8) {
    final platform = data.getUint16(offset);
    final encoding = data.getUint16(offset + 2);
    if (platform != 0 && (platform != 3 || (encoding != 1 && encoding != 10))) {
      continue;
    }
    final table = base + data.getUint32(offset + 4);
    if (data.getUint16(table) == 12) {
      final groups = data.getUint32(table + 12);
      for (
        var group = table + 16;
        group < table + 16 + groups * 12;
        group += 12
      ) {
        final first = data.getUint32(group);
        final last = data.getUint32(group + 4);
        final glyph = data.getUint32(group + 8);
        for (var point = first + (glyph == 0 ? 1 : 0); point <= last; point++) {
          result.add(point);
        }
      }
    } else if (data.getUint16(table) == 4) {
      final count = data.getUint16(table + 6) ~/ 2;
      final ends = table + 14;
      final starts = ends + count * 2 + 2;
      final deltas = starts + count * 2;
      final ranges = deltas + count * 2;
      for (var segment = 0; segment < count; segment++) {
        final first = data.getUint16(starts + segment * 2);
        final last = data.getUint16(ends + segment * 2);
        final delta = data.getUint16(deltas + segment * 2);
        final location = ranges + segment * 2;
        final distance = data.getUint16(location);
        for (var point = first; point <= last && point < 0xffff; point++) {
          final glyph = distance == 0
              ? point
              : data.getUint16(location + distance + (point - first) * 2);
          if ((distance == 0 || glyph != 0) &&
              ((glyph + delta) & 0xffff) != 0) {
            result.add(point);
          }
        }
      }
    }
  }
  return result;
}

void main() {
  testWidgets('published icon font paints navigation and action glyphs', (
    tester,
  ) async {
    final path =
        Platform.environment['LANFLOW_RELEASE_ICON_FONT'] ??
        'build/windows/x64/runner/Release/data/flutter_assets/fonts/MaterialIcons-Regular.otf';
    await tester.runAsync(() async {
      final font = File(path);
      expect(
        await font.exists(),
        isTrue,
        reason: 'Build the release package before checking its font.',
      );
      final loader = FontLoader('LanFlowPublishedIcons')
        ..addFont(font.readAsBytes().then(ByteData.sublistView));
      await loader.load();
      final available = _fontCodepoints(await font.readAsBytes());
      for (final icon in _usedIcons().entries) {
        expect(
          available.contains(icon.value),
          isTrue,
          reason:
              'Published icon ${icon.key} U+${icon.value.toRadixString(16)} is missing.',
        );
      }
    });
    tester.view.physicalSize = const Size(64, 64);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    for (final icon in [
      Icons.chat_bubble_outline,
      Icons.chat_bubble_outline_rounded,
      Icons.restore_from_trash_outlined,
      Icons.palette_outlined,
      Icons.push_pin,
      Icons.push_pin_outlined,
      Icons.mark_chat_read_outlined,
      Icons.mark_chat_unread_outlined,
      Icons.info_outline_rounded,
      Icons.error_outline_rounded,
      Icons.folder_off_outlined,
      Icons.refresh_rounded,
      Icons.notes_rounded,
    ]) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: Colors.black,
              child: Center(
                child: Text(
                  String.fromCharCode(icon.codePoint),
                  style: const TextStyle(
                    fontFamily: 'LanFlowPublishedIcons',
                    color: Colors.white,
                    fontSize: 48,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final painted = await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final pixels = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();
        var count = 0;
        for (var index = 0; index < pixels!.lengthInBytes; index += 4) {
          if (pixels.getUint8(index) > 32) count++;
        }
        return count;
      });
      expect(
        painted,
        greaterThan(20),
        reason:
            'Published icon U+${icon.codePoint.toRadixString(16)} is blank.',
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
