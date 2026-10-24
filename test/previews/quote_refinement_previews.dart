import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/chat/chat_composer.dart';
import 'package:lanflow/ui/shared/app_root.dart';
import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();
  testWidgets('render dark quote rows from the actual composer', (tester) async {
    late InboxItem photo, text;
    await tester.runAsync(() async {
      for (final name in ['Roboto', 'Segoe UI', 'Microsoft YaHei UI', 'Microsoft YaHei']) {
        await (FontLoader(name)..addFont(File(r'C:\Windows\Fonts\msyh.ttc').readAsBytes().then(ByteData.sublistView))).load();
      }
      await (FontLoader('MaterialIcons')..addFont(File('build/unit_test_assets/fonts/MaterialIcons-Regular.otf').readAsBytes().then(ByteData.sublistView))).load();
      harness.lan.name = '7950X';
      final file = File('${harness.directory.path}/粘贴图片-1792659590610.png');
      await file.writeAsBytes(png); photo = (await harness.inbox.addFile(file.path)).item;
      text = (await harness.inbox.addText('那就对了'))!.item;
    });
    final controller = TextEditingController();
    final focus = FocusNode(); final hasText = ValueNotifier(false); final key = GlobalKey();
    addTearDown(() { controller.dispose(); focus.dispose(); hasText.dispose(); });
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    for (final wide in [true, false]) {
      await tester.runAsync(() => harness.inbox.setDraftQuote(MessageQuote.fromItem(wide ? photo : text)));
      tester.view.physicalSize = wide ? const Size(1180, 330) : const Size(390, 300);
      tester.view.devicePixelRatio = 1;
      final composer = ChatComposer(inbox: harness.inbox, controller: controller, focusNode: focus,
        editorMenuKey: GlobalKey(), hasText: hasText, saving: false, wide: wide, onCancelQuote: () {},
        onSend: () async {}, onPaste: () async {}, onNewline: () {}, onPick: (_) async {}, onAttachments: () async {});
      await tester.pumpWidget(AppRoot(themeMode: ThemeMode.dark,
        platform: wide ? TargetPlatform.windows : TargetPlatform.android,
        home: Scaffold(body: Align(alignment: Alignment.topLeft, child: RepaintBoundary(key: key,
          child: SizedBox(width: wide ? 1180 : 390, height: wide ? 300 : null, child: composer))))));
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('build/previews/quote-${wide ? 'desktop' : 'mobile'}-dark.png').writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
    }
    expect(tester.takeException(), isNull);
  });
}

