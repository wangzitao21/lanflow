import 'package:flutter/material.dart';
import 'avatar_choices.dart';
import 'device_avatar.dart';
import 'app_strings.dart';

class DeviceAvatarChoices extends StatelessWidget {
  const DeviceAvatarChoices({
    super.key,
    this.preset,
    this.color,
    this.platform,
    this.photo = false,
    required this.onPreset,
    required this.onColor,
  });
  final String? preset, platform;
  final int? color;
  final bool photo;
  final ValueChanged<String>? onPreset;
  final ValueChanged<int>? onColor;
  @override
  Widget build(BuildContext context) {
    final selected = photo ? null : preset ?? defaultDevicePreset(platform);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AvatarOptionGrid(
          maxColumns: 5,
          children: [
            for (final entry in deviceAvatarPresets.entries)
              Semantics(
                button: true,
                selected: selected == entry.key,
                child: InkWell(
                  key: ValueKey('device-avatar-preset-${entry.key}'),
                  onTap: onPreset == null ? null : () => onPreset!(entry.key),
                  borderRadius: BorderRadius.circular(6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DeviceAvatar(preset: entry.key, color: color, size: 48),
                      const SizedBox(height: 6),
                      Text(
                        entry.value.$1,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: selected == entry.key
                              ? FontWeight.w700
                              : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        Text(tr(context, '头像颜色')),
        const SizedBox(height: 12),
        AvatarColorChoices(
          selected:
              color ??
              deviceAvatarPresets[preset ?? defaultDevicePreset(platform)]?.$3,
          onChanged: onColor,
          keyPrefix: 'device-avatar-color',
        ),
      ],
    );
  }
}
