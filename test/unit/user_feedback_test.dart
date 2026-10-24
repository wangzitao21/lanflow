import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';

void main() {
  test(
    'unreviewed errors cannot expose paths, platform details or server text',
    () {
      const raw =
          '文件异常 /private/device/store.sqlite: SQLITE_BUSY, token=secret';
      for (final error in <Object>[
        raw,
        StateError(raw),
        const FormatException(raw),
        PlatformException(code: 'NATIVE', message: raw, details: raw),
        Exception(raw),
      ]) {
        expect(userError(error, fallback: '保存失败，请重试'), '保存失败，请重试');
      }
      expect(
        userError(
          const FileSystemException(raw, '/private/device'),
          fallback: '保存失败',
        ),
        '无法读写文件，请检查存储空间和权限',
      );
      expect(userError('草稿保存失败：$raw', fallback: '操作失败'), '草稿未保存，请重试');
    },
  );

  test(
    'validation and recovery remain actionable without exception wrappers',
    () {
      expect(
        userError(const FormatException('请选择 20 MB 以内的图片'), fallback: '读取失败'),
        '请选择 20 MB 以内的图片',
      );
      expect(
        userError(StateError('连接已失效，请重新配对'), fallback: '同步失败'),
        '连接已失效，请重新绑定',
      );
      expect(
        userError(
          PlatformException(code: 'MISSING', message: '文件不存在'),
          fallback: '打开失败',
        ),
        '文件不存在，请重新选择',
      );
    },
  );
}
