import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/ui/chat/share_receiver_page.dart';
import 'package:lanflow/ui/shared/app_root.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();
  testWidgets(
    'recovered partial share explains missing files before the user sends',
    (tester) async {
      Map<String, dynamic>? sent;
      await tester.pumpWidget(
        AppRoot(
          platform: TargetPlatform.android,
          home: ShareReceiverPage(
            inbox: harness.inbox,
            payload: {
              'id': 'recovered-share-0001',
              'text': '保留的文字',
              'recoveredMissing': 2,
              'files': [
                {
                  'path': '/completed.txt',
                  'name': 'completed.txt',
                  'mimeType': 'text/plain',
                },
              ],
            },
            onSend: (value) async {
              sent = value;
            },
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('recovered-share-notice')),
        findsOneWidget,
      );
      expect(find.textContaining('剩余 2 个文件'), findsOneWidget);
      expect(sent, isNull);
      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '发送'));
      await tester.pumpAndSettle();
      expect((sent!['files'] as List).length, 1);
      expect(sent!['text'], '保留的文字');
      expect(find.text('已发送'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
