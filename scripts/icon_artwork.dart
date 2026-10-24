import 'dart:ui' as ui;

class IconStroke {
  const IconStroke(this.data, this.color, this.width);
  final String data;
  final int color;
  final double width;
}

class IconArtwork {
  const IconArtwork(this.name, this.top, this.bottom, this.strokes);
  final String name;
  final int top, bottom;
  final List<IconStroke> strokes;
}

const iconDesigns = [
  IconArtwork('A  流线', 0xFF193B4D, 0xFF0C504C, [
    IconStroke('M 31 32 L 65 32 C 79 32 82 43 69 50 L 40 65', 0xFFF3FAF7, 11),
    IconStroke('M 40 65 C 28 72 32 78 43 78 L 77 78', 0xFF74D4BE, 11),
  ]),
  IconArtwork('B  双窗', 0xFF123B36, 0xFF156B5C, [
    IconStroke(
      'M 58 28 L 38 28 C 32 28 28 32 28 38 L 28 54 C 28 60 32 64 38 64 L 54 64 C 60 64 64 60 64 54 L 64 38 C 64 32 62 28 58 28 Z',
      0xFFF4FAF6,
      7,
    ),
    IconStroke(
      'M 70 44 L 54 44 C 48 44 44 48 44 54 L 44 70 C 44 76 48 80 54 80 L 70 80 C 76 80 80 76 80 70 L 80 54 C 80 48 76 44 70 44 Z',
      0xFF70CDB6,
      7,
    ),
  ]),
  IconArtwork('C  字母', 0xFFEEF5F1, 0xFFD9E9E4, [
    IconStroke('M 32 29 L 32 69 C 32 75 35 78 42 78 L 75 78', 0xFF18584E, 11),
    IconStroke('M 57 60 L 57 31 L 79 31 M 57 46 L 73 46', 0xFF399C87, 9),
  ]),
];

// All commands are absolute, so the native Android vector and desktop PNGs
// share precisely the same geometry.
ui.Path iconPath(String data) {
  final tokens = RegExp(
    r'[A-Z]|-?\d+(?:\.\d+)?',
  ).allMatches(data).map((m) => m.group(0)!).toList();
  var index = 0;
  double number() => double.parse(tokens[index++]);
  final path = ui.Path();
  while (index < tokens.length) {
    switch (tokens[index++]) {
      case 'M':
        path.moveTo(number(), number());
      case 'L':
        path.lineTo(number(), number());
      case 'C':
        path.cubicTo(
          number(),
          number(),
          number(),
          number(),
          number(),
          number(),
        );
      case 'Z':
        path.close();
      default:
        throw FormatException('Unsupported icon command');
    }
  }
  return path;
}

void paintIcon(ui.Canvas canvas, double size, IconArtwork artwork) {
  canvas.save();
  canvas.scale(size / 108);
  canvas.drawRRect(
    ui.RRect.fromRectAndRadius(
      const ui.Rect.fromLTWH(4, 4, 100, 100),
      const ui.Radius.circular(24),
    ),
    ui.Paint()
      ..shader = ui.Gradient.linear(
        const ui.Offset(12, 4),
        const ui.Offset(94, 104),
        [ui.Color(artwork.top), ui.Color(artwork.bottom)],
      ),
  );
  for (final stroke in artwork.strokes) {
    canvas.save();
    canvas.translate(54, 54);
    canvas.scale(.9);
    canvas.translate(-54, -54);
    canvas.drawPath(
      iconPath(stroke.data),
      ui.Paint()
        ..color = ui.Color(stroke.color)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = stroke.width
        ..strokeCap = ui.StrokeCap.round
        ..strokeJoin = ui.StrokeJoin.round,
    );
    canvas.restore();
  }
  canvas.restore();
}
