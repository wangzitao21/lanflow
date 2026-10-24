import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/sync_progress.dart';

void main() {
  testWidgets(
    'background reduces only display sampling and resume refreshes immediately',
    (tester) async {
      var reads = 0;
      final progress = SyncProgress(() => reads++);
      try {
        await tester.pump(const Duration(seconds: 6));
        expect(reads, 0);
        progress.start();
        await tester.pump(const Duration(milliseconds: 700));
        expect(reads, 2);
        progress.setForeground(false);
        await tester.pump(const Duration(seconds: 2));
        expect(reads, 2);
        await tester.pump(const Duration(seconds: 1));
        expect(reads, 3);
        progress.setForeground(true);
        expect(reads, 4);
        await tester.pump(const Duration(milliseconds: 350));
        expect(reads, 5);
        progress.stop();
        progress.setForeground(false);
        await tester.pump(const Duration(seconds: 6));
        expect(reads, 5);
      } finally {
        progress.stop();
      }
    },
  );
}
