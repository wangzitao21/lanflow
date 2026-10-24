import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/ui/shared/chat_theme.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  testWidgets('system appearance and reduced motion keep the same draft', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.runAsync(() => harness.inbox.setAppearance('system'));
    await harness.mount(tester);
    final editor = find.byKey(const ValueKey('inbox-composer'));
    await tester.enterText(editor, '系统主题变化时保留草稿');
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(editor)).brightness, Brightness.dark);
    expect(
      tester
          .widget<MaterialApp>(find.byType(MaterialApp))
          .themeAnimationDuration,
      Duration.zero,
    );
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(editor)).brightness, Brightness.light);
    expect(tester.widget<TextField>(editor).controller!.text, '系统主题变化时保留草稿');
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(
      ModalRoute.of(
        tester.element(find.byType(AlertDialog)),
      )!.transitionDuration,
      Duration.zero,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'message text, links and primary actions stay readable in both themes',
    () {
      double contrast(Color a, Color b) {
        final x = a.computeLuminance();
        final y = b.computeLuminance();
        return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
      }

      for (final brightness in Brightness.values) {
        final theme = chatTheme(brightness);
        final palette = theme.extension<ChatPalette>()!;
        expect(
          contrast(palette.outgoingText, palette.outgoing),
          greaterThan(4.5),
        );
        expect(
          contrast(palette.outgoingLink, palette.outgoing),
          greaterThan(4.5),
        );
        expect(
          contrast(theme.colorScheme.primary, theme.colorScheme.onPrimary),
          greaterThan(4.5),
        );
      }
    },
  );

  testWidgets('appearance switches the whole app without losing a draft', (
    tester,
  ) async {
    await harness.mount(tester);
    final editor = find.byKey(const ValueKey('inbox-composer'));
    await tester.enterText(editor, '深色切换保留草稿');
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final toggle = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('appearance-dark')),
      );
      toggle.onSelected!(true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(editor)).brightness, Brightness.dark);
    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect(
      dialog.backgroundColor ??
          Theme.of(tester.element(editor)).dialogTheme.backgroundColor,
      isNot(Colors.white),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(editor).controller!.text, '深色切换保留草稿');
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
