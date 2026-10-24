import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/sync_retry_policy.dart';

void main() {
  test(
    'offline retry grows to fifteen minutes instead of constant polling',
    () {
      expect(
        [for (var i = 1; i <= 8; i++) syncRetryDelay(i).inSeconds],
        [30, 60, 120, 240, 480, 900, 900, 900],
      );
    },
  );
}
