import 'package:lanflow/ui/shared/chat_theme.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'app_strings.dart';

const deviceAvatarPresets = <String, (String, IconData, int)>{
  'linux': ('Linux', Icons.terminal_rounded, 0xFF677585),
  'windows': ('Windows', Icons.window_rounded, 0xFF5B88AE),
  'android': ('Android', Icons.android_rounded, 0xFF07C160),
  'ios': ('iOS', Icons.phone_iphone_rounded, 0xFF487E78),
  'macos': ('Mac', Icons.laptop_mac_rounded, 0xFF7E63B5),
};

String defaultDevicePreset(String? platform) =>
    deviceAvatarPresets.containsKey(platform) ? platform! : 'windows';

// MemoryImage uses byte-buffer identity as its cache key. Decoding base64 on
// every build otherwise bypasses Flutter's image cache for every visible row.
final _avatarImages = <String, MemoryImage?>{};

MemoryImage? _avatarImage(String encoded) {
  if (_avatarImages.containsKey(encoded)) {
    final cached = _avatarImages.remove(encoded);
    _avatarImages[encoded] = cached;
    return cached;
  }
  MemoryImage? image;
  try {
    image = MemoryImage(base64Decode(encoded));
  } on FormatException {
    // Cache invalid input too, until the device supplies a new avatar.
  }
  _avatarImages[encoded] = image;
  if (_avatarImages.length > 16) _avatarImages.remove(_avatarImages.keys.first);
  return image;
}

class DeviceAvatar extends StatelessWidget {
  const DeviceAvatar({
    super.key,
    this.image,
    this.name = '',
    this.platform,
    this.size = 40,
    this.local = false,
    this.preset,
    this.color,
  });
  final String? image;
  final String name;
  final String? platform;
  final double size;
  final bool local;
  final String? preset;
  final int? color;
  @override
  Widget build(BuildContext context) {
    final selected =
        deviceAvatarPresets[preset] ??
        deviceAvatarPresets[defaultDevicePreset(platform)]!;
    final background = Color(color ?? selected.$3);
    final fallback = Container(
      color: background,
      child: Icon(selected.$2, color: Colors.white, size: size * .51),
    );
    Widget child = fallback;
    if (image != null && image!.isNotEmpty) {
      final provider = _avatarImage(image!);
      if (provider != null) {
        child = Image(
          image: provider,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => fallback,
        );
        if (color != null) {
          child = ColoredBox(
            color: background,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: child,
              ),
            ),
          );
        }
      }
    }
    return Semantics(
      label: name.isEmpty
          ? tr(context, '设备头像')
          : tr(context, '{name}的头像', {'name': name}),
      image: true,
      child: SizedBox(
        width: size,
        height: size,
        child: ClipRRect(borderRadius: AppCorners.border, child: child),
      ),
    );
  }
}
