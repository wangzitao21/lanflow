import 'dart:io';

import 'package:flutter/material.dart';

import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/ui/shared/device_avatar.dart';
import 'inbox_labels.dart';

class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    required this.inbox,
    required this.local,
    this.platform,
    this.deviceId,
    this.size = 40,
  });

  final InboxController inbox;
  final bool local;
  final String? platform;
  final String? deviceId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final id =
        deviceId ??
        (local && inbox.lan.identityReady ? inbox.lan.identity.id : '');
    return DeviceAvatar(
      size: size,
      local: local,
      image: inbox.deviceAvatar(id),
      preset: inbox.deviceAvatarPreset(id),
      color: inbox.deviceAvatarColor(id),
      name: inbox.lan.identityReady ? deviceLabel(context, inbox, id) : '',
      platform: platform ?? (local ? Platform.operatingSystem : 'windows'),
    );
  }
}
