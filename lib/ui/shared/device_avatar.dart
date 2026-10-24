import 'package:lanflow/ui/shared/chat_theme.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'app_strings.dart';

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
  });
  final String? image;
  final String name;
  final String? platform;
  final double size;
  final bool local;
  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: local
              ? const [Color(0xFF3CC697), Color(0xFF119778)]
              : const [Color(0xFF8BAEB6), Color(0xFF56818D)],
        ),
      ),
      child: Icon(
        platform == 'android'
            ? Icons.phone_android_rounded
            : Icons.laptop_rounded,
        color: Colors.white,
        size: size * .51,
      ),
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
