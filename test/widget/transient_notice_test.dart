import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/ui/shared/app_feedback.dart';
import 'package:lanflow/ui/shared/app_root.dart';
import 'package:lanflow/ui/shared/runtime_feedback.dart';

void main() {
  testWidgets(
    'every runtime completion expires within one second without acknowledgement',
    (tester) async {
      for (final notice in ['已清空回收站', '数据已迁移到新位置', '完整备份已保存', '缓存已清理']) {
        var dismissed = false;
        await tester.pumpWidget(
          AppRoot(
            home: RuntimeFeedback(
              key: ValueKey(notice),
              changing: false,
              progress: '',
              notice: notice,
              onDismiss: () => dismissed = true,
              child: const Scaffold(),
            ),
          ),
        );
        expect(find.text(notice), findsOneWidget);
        expect(find.text('知道了'), findsNothing);
        await tester.pump(const Duration(milliseconds: 1000));
        expect(find.text(notice), findsNothing);
        expect(dismissed, isTrue);
      }
    },
  );
  testWidgets(
    'queued feedback expires during accessible navigation and replacement',
    (tester) async {
      late BuildContext target;
      await tester.pumpWidget(
        AppRoot(
          home: MediaQuery(
            data: const MediaQueryData(accessibleNavigation: true),
            child: Scaffold(
              body: Builder(
                builder: (context) {
                  target = context;
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      showAppMessage(
        target,
        '已加入收藏',
        action: SnackBarAction(label: '查看', onPressed: () {}),
        duration: const Duration(days: 1),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      showAppMessage(target, '文件已保存');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1000));
      expect(find.byType(SnackBar), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
