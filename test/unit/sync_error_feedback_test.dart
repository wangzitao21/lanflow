import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';

void main() {
  test(
    'durable failure categories survive display sanitizing and translation',
    () {
      for (final category in [
        'busy',
        'paused',
        'not_ready',
        'timeout',
        'offline',
        'identity',
        'authentication',
        'storage',
        'remote_storage',
        'protocol',
        'conflict',
        'integrity',
      ]) {
        final task = TransferTask.fromJson({
          'endpoint': 'device:test',
          'direction': 'upload',
          'eventId': 'event',
          'item': {
            'id': 'a' * 32,
            'originId': 'b' * 32,
            'originName': 'Device',
            'createdAt': '2026-10-25T00:00:00Z',
            'kind': 'file',
            'name': 'file.bin',
            'text': '',
            'size': 1,
            'sha256': 'c' * 64,
          },
          'transferred': 0,
          'state': 'failed',
          'errorCategory': category,
          'error': 'private path /data/history.sqlite and token=secret',
        });
        final displayed = userError(task.error, fallback: 'generic failure');
        expect(displayed, isNot('generic failure'), reason: category);
        expect(displayed, isNot(contains('secret')));
        expect(displayed, isNot(contains('/data')));
        expect(
          translateProductText(displayed, language: 'en'),
          isNot(matches(RegExp(r'[\u4e00-\u9fff]'))),
        );
        if ([
          'busy',
          'paused',
          'not_ready',
          'offline',
          'timeout',
        ].contains(category)) {
          expect(task.needsAttention, isFalse);
        } else {
          expect(task.needsAttention, isTrue);
        }
      }
    },
  );
}
