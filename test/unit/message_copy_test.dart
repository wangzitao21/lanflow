import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/files/message_copy.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';

void main() {
  InboxEntry message(String id, int minute, String text, {String name = ''}) =>
      InboxEntry(
        0,
        InboxItem(
          id: id,
          originId: 'test',
          originName: 'test',
          createdAt: DateTime.utc(2026, 10, 29, 0, minute),
          kind: name.isEmpty ? MessageKind.text : MessageKind.file,
          text: text,
          name: name,
        ),
      );
  test(
    'merged copy follows history order rather than click order and preserves paragraph content',
    () {
      final selected = [
        message('c', 2, '最后'),
        message('a', 1, '第一行\n第二行'),
        message('b', 1, '中间'),
      ];
      expect(mergedMessageText(selected), '第一行\n第二行\n\n中间\n\n最后');
      expect(
        mergedMessageText(selected, numbered: true),
        '1. 第一行\n第二行\n\n2. 中间\n\n3. 最后',
      );
      expect(selected.first.item.id, 'c');
    },
  );
  test(
    'attachments retain their name and any accompanying link or caption',
    () {
      expect(
        mergedMessageText([
          message('a', 1, 'https://example.com/source', name: '研究数据.csv'),
        ]),
        '研究数据.csv\nhttps://example.com/source',
      );
    },
  );
}
