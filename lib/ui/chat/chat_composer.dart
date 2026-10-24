import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/app_feedback.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'editor_context_menu.dart';
import 'touch_composer_editor.dart';
import 'quote_preview.dart';

class ChatComposer extends StatelessWidget {
  const ChatComposer({
    super.key,
    required this.inbox,
    required this.controller,
    required this.focusNode,
    required this.editorMenuKey,
    required this.hasText,
    required this.saving,
    this.preparing = false,
    this.picking = false,
    required this.wide,
    required this.onSend,
    required this.onPaste,
    required this.onNewline,
    required this.onPick,
    required this.onAttachments,
    this.selectionActions,
    this.onEdit,
    this.onCancelQuote,
    this.attachmentPanel,
  });

  final InboxController inbox;
  final TextEditingController controller;
  final FocusNode focusNode;
  final GlobalKey editorMenuKey;
  final ValueListenable<bool> hasText;
  final bool saving;
  final bool preparing;
  final bool picking;
  final bool wide;
  final AsyncCallback onSend;
  final AsyncCallback onPaste;
  final VoidCallback onNewline;
  final Future<void> Function(bool media) onPick;
  final AsyncCallback onAttachments;
  final Widget? selectionActions;
  final VoidCallback? onEdit, onCancelQuote;
  final Widget? attachmentPanel;

  Widget _quote(bool mobile) {
    final quote = inbox.store.draftQuotes[inbox.conversationId]!;
    final source = inbox.store.find(quote.id)?.item;
    return QuotePreview(
      quote: quote,
      draft: true,
      mobile: mobile,
      onClose: onCancelQuote,
      source: source,
      image: source?.kind == MessageKind.image
          ? inbox.store.blob(source!.digest)
          : null,
    );
  }

  Widget _selectionOverlay(Widget editor, {bool expand = false}) => Stack(
    fit: expand ? StackFit.expand : StackFit.passthrough,
    children: [
      Visibility(
        visible: selectionActions == null,
        maintainSize: true,
        maintainState: true,
        maintainAnimation: true,
        child: ExcludeFocus(excluding: selectionActions != null, child: editor),
      ),
      if (selectionActions != null)
        Positioned.fill(
          key: const ValueKey('composer-selection-panel'),
          child: selectionActions!,
        ),
    ],
  );

  Widget _draftPreviews(BuildContext context) {
    final palette = ChatPalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final labelHeight = scaler.scale(12) * 1.5;
    final detailsHeight = scaler.scale(13) * 1.5 + 4 + labelHeight;
    final cardHeight = math.max(52.0, detailsHeight) + 24;
    return SizedBox(
      height: math.max(104.0, labelHeight + 6 + cardHeight + 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              tr(context, '待发送 · {count} 个附件', {
                'count': inbox.store.draftAttachments.length,
              }),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: inbox.store.draftAttachments.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final item = inbox.store.draftAttachments[index];
                return Container(
                  key: ValueKey('draft-attachment-${item.id}'),
                  width: 250,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
                  decoration: BoxDecoration(
                    color: palette.sidebar,
                    borderRadius: AppCorners.border,
                    border: Border.all(color: palette.divider),
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: AppCorners.border,
                        child: item.kind == MessageKind.image
                            ? Image(
                                image: ResizeImage(
                                  FileImage(inbox.store.blob(item.digest)),
                                  width: 264,
                                  allowUpscaling: false,
                                ),
                                key: ValueKey('draft-image-${item.id}'),
                                width: 52,
                                height: 52,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const SizedBox(
                                  width: 52,
                                  child: Icon(Icons.image_outlined),
                                ),
                              )
                            : SizedBox(
                                width: 44,
                                child: Icon(
                                  item.kind == MessageKind.video
                                      ? Icons.movie_outlined
                                      : Icons.insert_drive_file_outlined,
                                ),
                              ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: AppTypography.compact,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              formatBytes(item.size),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: ValueKey('draft-remove-${item.id}'),
                        tooltip: tr(context, '移除 {name}', {'name': item.name}),
                        iconSize: 18,
                        onPressed: saving || preparing
                            ? null
                            : () async {
                                try {
                                  await inbox.removeDraftAttachment(item);
                                } on Object {
                                  if (context.mounted) {
                                    showAppMessage(context, '附件未能移除，请重试');
                                  }
                                }
                              },
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _editor(BuildContext context, bool wide) {
    return Actions(
      actions: {
        if (Theme.of(context).platform == TargetPlatform.windows)
          PasteTextIntent: CallbackAction<PasteTextIntent>(
            onInvoke: (_) {
              unawaited(onPaste());
              return null;
            },
          ),
      },
      child: CallbackShortcuts(
        bindings: {
          if (AppLayout.desktop(context))
            const SingleActivator(LogicalKeyboardKey.enter): () =>
                unawaited(onSend()),
          if (AppLayout.desktop(context))
            const SingleActivator(LogicalKeyboardKey.numpadEnter): () =>
                unawaited(onSend()),
          if (AppLayout.desktop(context))
            const SingleActivator(LogicalKeyboardKey.enter, shift: true):
                onNewline,
          if (AppLayout.desktop(context))
            const SingleActivator(LogicalKeyboardKey.numpadEnter, shift: true):
                onNewline,
          const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
              unawaited(onSend()),
          if (Theme.of(context).platform == TargetPlatform.windows)
            const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
                unawaited(onPaste()),
        },
        child: AppLayout.desktop(context)
            ? _textField(context, wide)
            : TouchComposerEditor(
                focusNode: focusNode,
                onEdit: onEdit,
                builder: (readOnly, onTap) =>
                    _textField(context, wide, readOnly: readOnly, onTap: onTap),
              ),
      ),
    );
  }

  Widget _textField(
    BuildContext context,
    bool wide, {
    bool readOnly = false,
    VoidCallback? onTap,
  }) {
    final palette = ChatPalette.of(context);
    return TextField(
      key: ValueKey('inbox-composer'),
      controller: controller,
      focusNode: focusNode,
      readOnly: readOnly,
      onTap: onTap,
      autofocus: wide,
      onTapOutside: (_) {
        // Desktop toolbar buttons are part of the editor's TapRegion.
        // A deliberate click into another control should own the next focus.
        if (AppLayout.desktop(context)) focusNode.unfocus();
      },
      enabled: inbox.ready && inbox.lan.ready,
      minLines: wide ? null : 1,
      maxLines: wide ? null : 4,
      expands: wide,
      textAlignVertical: TextAlignVertical.top,
      maxLength: 20000,
      style: TextStyle(
        fontSize: ChatMetrics.messageFontSize,
        height: ChatMetrics.messageLineHeight,
        letterSpacing: 0,
        color: palette.text,
      ),
      decoration: InputDecoration(
        hintText: tr(context, '发点什么…'),
        counterText: '',
        filled: !wide,
        fillColor: wide ? palette.editor : palette.surface,
        border: wide
            ? InputBorder.none
            : OutlineInputBorder(
                borderRadius: AppCorners.border,
                borderSide: BorderSide.none,
              ),
        enabledBorder: wide
            ? InputBorder.none
            : OutlineInputBorder(
                borderRadius: AppCorners.border,
                borderSide: BorderSide(color: palette.divider),
              ),
        focusedBorder: wide
            ? InputBorder.none
            : OutlineInputBorder(
                borderRadius: AppCorners.border,
                borderSide: BorderSide(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
        disabledBorder: InputBorder.none,
        contentPadding: EdgeInsets.symmetric(
          horizontal: wide ? 0 : 12,
          vertical: wide ? 0 : 10,
        ),
      ),
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      contextMenuBuilder: (context, editable) {
        final items = [
          ...editable.contextMenuButtonItems.where(
            (item) => item.type != ContextMenuButtonType.paste,
          ),
          ContextMenuButtonItem(
            type: ContextMenuButtonType.paste,
            onPressed: () {
              ContextMenuController.removeAny();
              unawaited(onPaste());
            },
          ),
        ];
        if (AppLayout.desktop(context)) {
          return EditorContextMenu(
            panelKey: editorMenuKey,
            anchors: editable.contextMenuAnchors,
            items: items,
          );
        }
        return AdaptiveTextSelectionToolbar.buttonItems(
          key: editorMenuKey,
          anchors: editable.contextMenuAnchors,
          buttonItems: items,
        );
      },
    );
  }

  Widget _sendButton(BuildContext context, {bool desktop = false}) {
    return ValueListenableBuilder<bool>(
      valueListenable: hasText,
      builder: (_, hasText, _) => FilledButton(
        onPressed:
            saving ||
                preparing ||
                !inbox.ready ||
                !inbox.lan.ready ||
                (!hasText && inbox.store.draftAttachments.isEmpty)
            ? null
            : onSend,
        style: FilledButton.styleFrom(
          padding: EdgeInsets.symmetric(
            horizontal: desktop ? 20 : 17,
            vertical: desktop ? 8 : 11,
          ),
          minimumSize: Size(76, desktop ? 36 : 48),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(fontSize: desktop ? 13 : 15),
          shape: RoundedRectangleBorder(borderRadius: AppCorners.border),
        ),
        child: Text(tr(context, saving ? '发送中' : '发送')),
      ),
    );
  }

  double _mobileSendWidth(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(
        text: tr(context, saving ? '发送中' : '发送'),
        style: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 15),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = math.max(76.0, painter.width + 34);
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final palette = ChatPalette.of(context);
    final tools = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: tr(context, '添加图片或视频'),
          onPressed:
              saving || preparing || picking || !inbox.ready || !inbox.lan.ready
              ? null
              : () => onPick(true),
          icon: Icon(Icons.image_outlined, size: 23),
        ),
        IconButton(
          tooltip: tr(context, '添加文件'),
          onPressed:
              saving || preparing || picking || !inbox.ready || !inbox.lan.ready
              ? null
              : () => onPick(false),
          icon: Icon(Icons.folder_open_outlined, size: 24),
        ),
      ],
    );
    if (wide) {
      final contents = Padding(
        padding: const EdgeInsets.fromLTRB(16, 15, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (preparing)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  tr(context, '正在准备附件…'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (inbox.store.draftAttachments.isNotEmpty)
              _draftPreviews(context),
            Expanded(child: _editor(context, true)),
            const SizedBox(height: 8),
            if (inbox.store.draftQuotes.containsKey(inbox.conversationId))
              TextFieldTapRegion(child: _quote(false)),
            SizedBox(
              height: 48,
              child: TextFieldTapRegion(
                child: Row(
                  children: [
                    tools,
                    const Spacer(),
                    Tooltip(
                      message: tr(
                        context,
                        AppLayout.desktop(context)
                            ? 'Enter 发送，Shift+Enter 换行'
                            : '发送（Ctrl+Enter）',
                      ),
                      child: _sendButton(context, desktop: true),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: ListenableBuilder(
          listenable: focusNode,
          child: _selectionOverlay(contents, expand: true),
          builder: (context, child) => Container(
            key: const ValueKey('chat-composer-panel'),
            decoration: BoxDecoration(
              color: palette.editor,
              borderRadius: AppCorners.border,
              border: Border.all(
                color: focusNode.hasFocus
                    ? Theme.of(context).colorScheme.primary
                    : palette.divider,
              ),
            ),
            child: child,
          ),
        ),
      );
    }
    return TextFieldTapRegion(
      child: Container(
        key: ValueKey('chat-composer-panel'),
        decoration: BoxDecoration(
          color: palette.canvas,
          border: Border(top: BorderSide(color: palette.divider, width: .6)),
        ),
        padding: const EdgeInsets.fromLTRB(6, 7, 12, 7),
        child: _selectionOverlay(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (inbox.store.draftAttachments.isNotEmpty)
                _draftPreviews(context),
              if (preparing)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    tr(context, '正在准备附件…'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: tr(context, '添加内容'),
                    onPressed:
                        saving ||
                            preparing ||
                            picking ||
                            !inbox.ready ||
                            !inbox.lan.ready
                        ? null
                        : onAttachments,
                    icon: Icon(Icons.add_circle_outline_rounded, size: 26),
                  ),
                  Expanded(child: _editor(context, false)),
                  SizedBox(width: 8),
                  TextFieldTapRegion(
                    child: Tooltip(
                      message: tr(
                        context,
                        AppLayout.desktop(context)
                            ? 'Enter 发送，Shift+Enter 换行'
                            : '发送',
                      ),
                      child: SizedBox(
                        width: _mobileSendWidth(context),
                        child: _sendButton(context),
                      ),
                    ),
                  ),
                ],
              ),
              if (inbox.store.draftQuotes.containsKey(inbox.conversationId))
                Padding(
                  padding: EdgeInsets.only(
                    left: 48,
                    right: _mobileSendWidth(context) + 8,
                    top: 4,
                  ),
                  child: _quote(true),
                ),
              ?attachmentPanel,
            ],
          ),
        ),
      ),
    );
  }
}
