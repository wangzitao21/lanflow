import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/ui/chat/editor_context_menu.dart';
import 'package:lanflow/ui/shared/app_root.dart';
import 'package:lanflow/ui/shared/app_feedback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String clipboard = '';
  setUp(() {
    clipboard = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          if (call.method == 'Clipboard.hasStrings') {
            return {'value': clipboard.isNotEmpty};
          }
          return null;
        });
  });
  tearDown(() {
    ContextMenuController.removeAny();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
    'editor uses the message menu surface and preserves cut copy paste and selection',
    (tester) async {
      final controller = TextEditingController(text: 'alpha beta gamma');
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      final panelKey = GlobalKey();
      await tester.pumpWidget(
        AppRoot(
          platform: TargetPlatform.windows,
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(40),
              child: TextField(
                controller: controller,
                focusNode: focus,
                autofocus: true,
                contextMenuBuilder: (context, editable) => EditorContextMenu(
                  panelKey: panelKey,
                  anchors: editable.contextMenuAnchors,
                  items: editable.contextMenuButtonItems,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> open(TextSelection selection) async {
        focus.requestFocus();
        controller.selection = selection;
        await tester.pump();
        tester
            .state<EditableTextState>(find.byType(EditableText))
            .showToolbar();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('desktop-context-menu')),
          findsOneWidget,
        );
      }

      await open(const TextSelection(baseOffset: 6, extentOffset: 10));
      await tester.tap(find.byKey(const ValueKey('desktop-menu-editor-copy')));
      await tester.pumpAndSettle();
      expect(clipboard, 'beta');
      expect(controller.text, 'alpha beta gamma');
      await open(const TextSelection(baseOffset: 6, extentOffset: 10));
      await tester.tap(find.byKey(const ValueKey('desktop-menu-editor-cut')));
      await tester.pumpAndSettle();
      expect(controller.text, 'alpha  gamma');
      await open(const TextSelection.collapsed(offset: 6));
      await tester.tap(find.byKey(const ValueKey('desktop-menu-editor-paste')));
      await tester.pumpAndSettle();
      expect(controller.text, 'alpha beta gamma');
      await open(const TextSelection.collapsed(offset: 0));
      await tester.tap(
        find.byKey(const ValueKey('desktop-menu-editor-selectAll')),
      );
      await tester.pumpAndSettle();
      expect(controller.selection.textInside(controller.text), controller.text);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('editor menu keyboard navigation never submits the draft', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'keep draft');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    var submitted = 0;
    await tester.pumpWidget(
      AppRoot(
        platform: TargetPlatform.windows,
        home: Scaffold(
          body: TextField(
            controller: controller,
            focusNode: focus,
            autofocus: true,
            onSubmitted: (_) => submitted++,
            contextMenuBuilder: (context, editable) => EditorContextMenu(
              panelKey: const ValueKey('editor-menu'),
              anchors: editable.contextMenuAnchors,
              items: editable.contextMenuButtonItems,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    await tester.pump();
    tester.state<EditableTextState>(find.byType(EditableText)).showToolbar();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(submitted, 0);
    expect(find.byKey(const ValueKey('desktop-context-menu')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('deletion feedback expires after one second even with Undo', (
    tester,
  ) async {
    late BuildContext target;
    await tester.pumpWidget(
      AppRoot(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              target = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    showAppMessage(target, '已加入收藏');
    await tester.pumpAndSettle();
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).duration,
      const Duration(seconds: 1),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    showAppMessage(
      target,
      '已删除',
      action: SnackBarAction(label: '撤销', onPressed: () {}),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).duration,
      const Duration(seconds: 1),
    );
    expect(find.text('撤销'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });
}
