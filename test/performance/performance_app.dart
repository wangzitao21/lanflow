import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'package:lanflow/main.dart' as application;

// Run as a Windows profile/release entrypoint with an isolated LANFLOW_DATA_DIR.
// This exercises the real engine and rasterizer, rather than a widget-test clock.
Future<void> main() async {
  final watch = Stopwatch()..start();
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final frames = <FrameTiming>[];
  binding.addTimingsCallback(frames.addAll);
  int? firstFrameMs;
  unawaited(
    binding.waitUntilFirstFrameRasterized.then((_) {
      firstFrameMs = watch.elapsedMilliseconds;
    }),
  );
  final output = Platform.environment['LANFLOW_BENCHMARK_OUTPUT'];
  if (output == null || Platform.environment['LANFLOW_DATA_DIR'] == null) {
    throw StateError('Performance runs require isolated data and output paths');
  }
  try {
    await application.main();
    await _until(
      () => _elements(
        (w) =>
            w is TextField &&
            w.key == const ValueKey('inbox-composer') &&
            w.enabled == true,
      ).isNotEmpty,
    );
    final readyMs = watch.elapsedMilliseconds;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final startup = await const MethodChannel(
      'lanflow/desktop',
    ).invokeMapMethod<String, dynamic>('startupTiming');
    final editor =
        _elements(
              (w) =>
                  w is TextField && w.key == const ValueKey('inbox-composer'),
            ).single.widget
            as TextField;
    final menuTimes = <int>[];
    final typingFrames = <FrameTiming>[];
    for (var i = 0; i < 12; i++) {
      editor.controller!.text = '性能测试：正在输入第 $i 条草稿';
      await _frame();
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    typingFrames.addAll(frames);
    frames.clear();
    for (var i = 0; i < 10; i++) {
      final bubbles = _elements(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('inbox-item-'),
      );
      final viewport = binding.platformDispatcher.views.first;
      final height = viewport.physicalSize.height / viewport.devicePixelRatio;
      final target = bubbles.lastWhere((element) {
        final box = element.findRenderObject();
        if (box is! RenderBox || !box.hasSize) return false;
        final y = box.localToGlobal(box.size.center(Offset.zero)).dy;
        return y > 110 && y < height - 245;
      });
      final box = target.findRenderObject()! as RenderBox;
      final position = box.localToGlobal(box.size.center(Offset.zero));
      final menuWatch = Stopwatch()..start();
      GestureBinding.instance.handlePointerEvent(
        PointerDownEvent(
          pointer: 30 + i,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
          position: position,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 8));
      GestureBinding.instance.handlePointerEvent(
        PointerUpEvent(
          pointer: 30 + i,
          kind: PointerDeviceKind.mouse,
          position: position,
        ),
      );
      await _until(() {
        return _elements(
          (w) => w.key == const ValueKey('desktop-context-menu'),
        ).isNotEmpty;
      });
      menuTimes.add(menuWatch.elapsedMicroseconds);
      GestureBinding.instance.handlePointerEvent(
        PointerDownEvent(
          pointer: 100 + i,
          kind: PointerDeviceKind.mouse,
          position: const Offset(350, 80),
        ),
      );
      GestureBinding.instance.handlePointerEvent(
        PointerUpEvent(
          pointer: 100 + i,
          kind: PointerDeviceKind.mouse,
          position: const Offset(350, 80),
        ),
      );
      await _until(
        () => _elements(
          (w) => w.key == const ValueKey('desktop-context-menu'),
        ).isEmpty,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await File(output).writeAsString(
      jsonEncode({
        'firstFrameMs': firstFrameMs,
        'nativeStartup': startup,
        'readyMs': readyMs,
        'menuFullyVisibleMs': _stats(menuTimes),
        'menuBuildMs': _stats(
          frames.map((v) => v.buildDuration.inMicroseconds),
        ),
        'menuRasterMs': _stats(
          frames.map((v) => v.rasterDuration.inMicroseconds),
        ),
        'startupAndTypingBuildMs': _stats(
          typingFrames.map((v) => v.buildDuration.inMicroseconds),
        ),
        'startupAndTypingRasterMs': _stats(
          typingFrames.map((v) => v.rasterDuration.inMicroseconds),
        ),
        'menuFramesOver16ms': frames
            .where(
              (v) =>
                  v.buildDuration.inMicroseconds > 16667 ||
                  v.rasterDuration.inMicroseconds > 16667,
            )
            .length,
        'menuFrames': frames.length,
      }),
    );
  } on Object catch (error, stack) {
    await File(
      output,
    ).writeAsString(jsonEncode({'error': '$error', 'stack': '$stack'}));
  } finally {
    await const MethodChannel('lanflow/desktop').invokeMethod<void>('quit');
  }
}

List<Element> _elements(bool Function(Widget) matches) {
  final result = <Element>[];
  void visit(Element element) {
    if (matches(element.widget)) result.add(element);
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return result;
}

Future<void> _frame() async {
  SchedulerBinding.instance.scheduleFrame();
  await SchedulerBinding.instance.endOfFrame;
}

Future<void> _until(bool Function() done) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed.inSeconds > 15) {
      throw TimeoutException('UI did not settle');
    }
    await _frame();
    await Future<void>.delayed(const Duration(milliseconds: 4));
  }
}

Map<String, num> _stats(Iterable<int> values) {
  final sorted = values.toList()..sort();
  if (sorted.isEmpty) return {'count': 0};
  return {
    'count': sorted.length,
    'median': sorted[sorted.length ~/ 2] / 1000,
    'p95': sorted[((sorted.length - 1) * .95).round()] / 1000,
    'max': sorted.last / 1000,
  };
}
