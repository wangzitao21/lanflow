import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';

import '../support/test_device.dart';

void main() {
  test('pins, colors, read markers and deletion survive reopening', () async {
    final root = await Directory.systemTemp.createTemp(
      'lanflow-conversation-state-',
    );
    var phone = await TestDevice.create('${root.path}/phone', '手机');
    var pc = await TestDevice.create('${root.path}/pc', '电脑');
    try {
      pc.lan.onPrompt = (_) async => true;
      final peer = await phone.lan.addAddress('127.0.0.1:${pc.lan.self.port}');
      await phone.lan.connect(peer);
      final work = await phone.inbox.createConversation('工作');
      final first = (await phone.inbox.addText('收到后显示未读'))!;
      await phone.inbox.syncNow();
      expect(pc.inbox.unreadCount(work.id), 1);
      pc.inbox.selectConversation(work.id);
      pc.inbox.setReadingConversation(work.id);
      expect(pc.inbox.isUnread(work.id), isFalse);
      await phone.inbox.addText('当前会话在前台阅读');
      await phone.inbox.syncNow();
      expect(pc.inbox.isUnread(work.id), isFalse);
      pc.inbox.setReadingConversation(null);
      await phone.inbox.addText('窗口在后台');
      await phone.inbox.syncNow();
      expect(pc.inbox.unreadCount(work.id), 1);
      await pc.inbox.addText('本机发送不增加未读');
      expect(pc.inbox.unreadCount(work.id), 1);
      pc.inbox.selectConversation(work.id, markRead: false);
      expect(
        pc.inbox.unreadCount(work.id),
        1,
        reason: 'Filtered search results do not read the entire conversation',
      );
      await pc.inbox.setConversationUnread(work.id, false);
      await pc.inbox.setConversationUnread(work.id, true);
      pc.inbox.setReadingConversation(work.id);
      expect(
        pc.inbox.isUnread(work.id),
        isTrue,
        reason: 'Explicit unread marks remain until reopening',
      );
      await pc.inbox.setConversationPinned(work.id, true);
      await pc.inbox.setConversationAvatar(work.id, 'book', color:0xFFDCE7F3);
      expect(pc.inbox.conversations.first.id, work.id);
      await pc.close();
      pc.inbox.dispose();
      pc.lan.dispose();
      pc = await TestDevice.create('${root.path}/pc', '电脑');
      expect(pc.inbox.isUnread(work.id), isTrue);
      expect(pc.inbox.conversationAvatarColor(work.id), 0xFFDCE7F3);
      expect(pc.inbox.conversations.first.id, work.id);
      pc.inbox.selectConversation(work.id);
      expect(pc.inbox.isUnread(work.id), isFalse);
      await pc.inbox.deleteConversation(work.id);
      expect(pc.inbox.conversations.any((item) => item.id == work.id), isFalse);
      expect(await pc.inbox.store.recentlyDeleted(), isNotEmpty);
      await pc.inbox.restoreItem(first.item);
      expect(pc.inbox.conversations.any((item) => item.id == work.id), isTrue);
      expect(
        pc.inbox.conversations.any((item) => item.id == defaultConversationId),
        isTrue,
      );
    } finally {
      await phone.close();
      await pc.close();
      phone.inbox.dispose();
      phone.lan.dispose();
      pc.inbox.dispose();
      pc.lan.dispose();
      await root.delete(recursive: true);
    }
  });
}
