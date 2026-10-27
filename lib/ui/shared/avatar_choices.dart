import 'package:flutter/material.dart';
import 'app_strings.dart';

const avatarColors = [
  0xFF07C160,
  0xFF5B88AE,
  0xFF7E63B5,
  0xFFC66682,
  0xFFB47B36,
  0xFF487E78,
  0xFF677585,
];

class AvatarOptionGrid extends StatelessWidget {
  const AvatarOptionGrid({
    super.key,
    required this.children,
    this.maxColumns = 4,
  });
  final List<Widget> children;
  final int maxColumns;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final columns = (bounds.maxWidth / 80).floor().clamp(1, maxColumns);
      final width = (bounds.maxWidth - (columns - 1) * 16) / columns;
      return Wrap(
        alignment: WrapAlignment.center,
        spacing: 16,
        runSpacing: 18,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}

class AvatarColorChoices extends StatelessWidget {
  const AvatarColorChoices({
    super.key,
    required this.selected,
    required this.onChanged,
    required this.keyPrefix,
  });
  final int? selected;
  final ValueChanged<int>? onChanged;
  final String keyPrefix;
  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.center,
    spacing: 12,
    runSpacing: 12,
    children: [
      for (final color in avatarColors)
        Semantics(
          button: true,
          selected: selected == color,
          label: tr(context, '头像颜色'),
          child: InkWell(
            key: ValueKey('$keyPrefix-$color'),
            onTap: onChanged == null ? null : () => onChanged!(color),
            customBorder: const CircleBorder(),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Color(color),
                shape: BoxShape.circle,
              ),
              child: selected == color
                  ? const Icon(Icons.check, color: Colors.white, size: 20)
                  : null,
            ),
          ),
        ),
    ],
  );
}
