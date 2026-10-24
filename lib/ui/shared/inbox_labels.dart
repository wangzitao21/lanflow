import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';

import 'app_strings.dart';

String syncTargetLabel(
  BuildContext context,
  InboxController inbox,
  SyncTarget target,
) {
  if (target.isHub || !target.key.startsWith('device:')) return target.name;
  final id = target.key.substring('device:'.length);
  final hasName =
      inbox.store.profiles[id]?['name'] is String ||
      inbox.lan.peers[id] != null;
  return !hasName &&
          target.name == '已绑定设备' &&
          Localizations.maybeLocaleOf(context)?.languageCode == 'en'
      ? tr(context, '已绑定的设备')
      : target.name;
}

String endpointLabel(BuildContext context, InboxController inbox, String key) {
  final target = inbox.syncTargets.where((item) => item.key == key).firstOrNull;
  return target == null
      ? tr(context, '未连接的设备')
      : syncTargetLabel(context, inbox, target);
}

String deviceLabel(BuildContext context, InboxController inbox, String id) {
  final profile = inbox.store.profiles[id]?['name'];
  if (profile is String) return profile;
  if (inbox.lan.identityReady && id == inbox.lan.identity.id) {
    return inbox.lan.name;
  }
  return inbox.lan.peers[id]?.name ?? tr(context, '我的设备');
}
