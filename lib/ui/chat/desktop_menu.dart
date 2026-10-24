import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:lanflow/ui/chat/message_actions.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/app_strings.dart';

/// An unmodal desktop menu. Outside clicks reach their original target, so a
/// right click on another bubble can replace this menu in the same event.
class DesktopMenuController {
  OverlayEntry? _entry;
  Completer<String?>? _result;
  final _panelKey = GlobalKey();

  bool get isOpen => _entry != null;

  Future<String?> show({
    required BuildContext context,
    required Offset position,
    required List<MessageAction> actions,
    bool takeFocus = true,
  }) {
    close();
    ContextMenuController.removeAny();
    final result = Completer<String?>();
    _result = result;
    final overlay = Overlay.of(context, rootOverlay: true);
    final box = overlay.context.findRenderObject()! as RenderBox;
    final point = box.globalToLocal(position);
    final themes = InheritedTheme.capture(from: context, to: overlay.context);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => themes.wrap(
        DesktopActionMenu(
          panelKey: _panelKey,
          position: point,
          actions: actions,
          takeFocus: takeFocus,
          onClose: () {
            // A newer menu may already have opened during this pointer event.
            if (identical(entry, _entry)) close();
          },
          onSelected: (value) {
            if (identical(entry, _entry)) close(value);
          },
        ),
      ),
    );
    _entry = entry;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointerEvent);
    overlay.insert(entry);
    return result.future;
  }

  void _pointerEvent(PointerEvent event) {
    if (event is! PointerSignalEvent) return;
    final box = _panelKey.currentContext?.findRenderObject();
    if (box is RenderBox &&
        (box.localToGlobal(Offset.zero) & box.size).contains(event.position)) {
      return;
    }
    close();
  }

  void close([String? action]) {
    final entry = _entry;
    if (entry == null) return;
    _entry = null;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointerEvent);
    entry.remove();
    entry.dispose();
    ContextMenuController.removeAny();
    _result?.complete(action);
    _result = null;
  }

  void dispose() => close();
}

class DesktopActionMenu extends StatefulWidget {
  const DesktopActionMenu({
    super.key,
    required this.panelKey,
    required this.position,
    required this.actions,
    required this.takeFocus,
    required this.onClose,
    required this.onSelected,
    this.handleKeysWithoutFocus = false,
  });
  final Key panelKey;
  final Offset position;
  final List<MessageAction> actions;
  final bool takeFocus;
  final VoidCallback onClose;
  final ValueChanged<String> onSelected;
  final bool handleKeysWithoutFocus;

  @override
  State<DesktopActionMenu> createState() => _DesktopMenuState();
}

class _DesktopMenuState extends State<DesktopActionMenu> {
  int _highlight = -1;
  final _focus = FocusNode(debugLabel: 'Desktop context menu');

  @override
  void initState() {
    super.initState();
    if (widget.handleKeysWithoutFocus) {
      FocusManager.instance.addEarlyKeyEventHandler(_handleEditorKey);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.takeFocus) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    if (widget.handleKeysWithoutFocus) {
      FocusManager.instance.removeEarlyKeyEventHandler(_handleEditorKey);
    }
    _focus.dispose();
    super.dispose();
  }

  void _move(int delta) =>
      setState(() => _highlight = (_highlight + delta) % widget.actions.length);

  KeyEventResult _handleEditorKey(KeyEvent event) {
    if (!mounted || (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _move(1);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _move(_highlight < 0 ? 0 : -1);
    } else if (event.logicalKey == LogicalKeyboardKey.enter) {
      if (event is KeyDownEvent && _highlight >= 0) {
        widget.onSelected(widget.actions[_highlight].value);
      }
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
    } else {
      widget.onClose();
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final p = ChatPalette.of(context);
    final screen = MediaQuery.sizeOf(context);
    final style = Theme.of(context).textTheme.bodyMedium!.copyWith(
      fontSize: AppTypography.secondary,
      letterSpacing: 0,
    );
    var labelWidth = 0.0;
    for (final action in widget.actions) {
      final painter = TextPainter(
        text: TextSpan(text: tr(context, action.label), style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      labelWidth = math.max(labelWidth, painter.width);
      painter.dispose();
    }
    final width = math.min(
      math.max(136.0, labelWidth.ceilToDouble() + 54),
      screen.width - 16,
    );
    final height =
        widget.actions.length * 38.0 +
        10 +
        (widget.actions.any((a) => a.destructive) ? 9 : 0);
    final left = widget.position.dx.clamp(8.0, screen.width - width - 8);
    final top = widget.position.dy.clamp(
      8.0,
      math.max(8.0, screen.height - height - 8),
    );
    return Stack(
      children: [
        Positioned(
          left: left,
          top: top.toDouble(),
          width: width,
          child: TapRegion(
            consumeOutsideTaps: false,
            onTapOutside: (_) => widget.onClose(),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape):
                    widget.onClose,
                const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                    _move(1),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                    _move(_highlight < 0 ? 0 : -1),
                const SingleActivator(LogicalKeyboardKey.enter): () {
                  if (_highlight >= 0) {
                    widget.onSelected(widget.actions[_highlight].value);
                  }
                },
              },
              child: Focus(
                focusNode: _focus,
                child: MouseRegion(
                  cursor: SystemMouseCursors.basic,
                  child: Material(
                    key: widget.panelKey,
                    color: p.menu,
                    elevation: 8,
                    shadowColor: Colors.black.withValues(alpha: .28),
                    shape: RoundedRectangleBorder(
                      borderRadius: AppCorners.border,
                      side: BorderSide(color: p.divider),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Padding(
                      key: const ValueKey('desktop-context-menu'),
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < widget.actions.length; i++) ...[
                            if (widget.actions[i].destructive && i > 0)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),
                                child: Divider(height: 1, color: p.divider),
                              ),
                            _row(widget.actions[i], i, p),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(MessageAction action, int index, ChatPalette p) {
    final color = action.destructive
        ? Theme.of(context).colorScheme.error
        : p.text;
    return Semantics(
      button: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _highlight = index),
        onExit: (_) => setState(() => _highlight = -1),
        child: InkWell(
          key: ValueKey('desktop-menu-${action.value}'),
          onTap: () => widget.onSelected(action.value),
          mouseCursor: SystemMouseCursors.basic,
          canRequestFocus: false,
          child: Container(
            height: 38,
            color: index == _highlight ? p.selected : null,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            child: Row(
              children: [
                Icon(action.icon, size: 18, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tr(context, action.label),
                    style: TextStyle(
                      fontSize: AppTypography.secondary,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
