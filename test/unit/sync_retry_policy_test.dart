import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/sync_retry_policy.dart';

void main() {
  test('offline retries start quickly and back off to one minute', () {
    expect(
      [for (var i = 1; i <= 8; i++) syncRetryDelay(i).inSeconds],
      [2, 4, 8, 16, 32, 60, 60, 60],
    );
  });
}
