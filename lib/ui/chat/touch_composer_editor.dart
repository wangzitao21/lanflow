import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Holding selects text without opening a previously closed keyboard.
class TouchComposerEditor extends StatefulWidget {
  const TouchComposerEditor({
    super.key,
    required this.focusNode,
    required this.builder,
    this.onEdit,
  });
  final FocusNode focusNode;
  final Widget Function(bool readOnly, VoidCallback onTap) builder;
  final VoidCallback? onEdit;
  @override
  State<TouchComposerEditor> createState() => _TouchComposerEditorState();
}

class _TouchComposerEditorState extends State<TouchComposerEditor> {
  bool _editing = false;
  bool _pointerDown = false;
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_focusChanged);
  }

  void _focusChanged() {
    if (widget.focusNode.hasFocus && !_pointerDown && !_editing) {
      setState(() => _editing = true);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_focusChanged);
    super.dispose();
  }

  void _edit() {
    widget.onEdit?.call();
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.focusNode.requestFocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    });
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) {
      _pointerDown = true;
      // Scaffold removes the keyboard inset from its body's MediaQuery.
      // Read the view itself so an open keyboard never becomes read-only on hold.
      final visible = View.of(context).viewInsets.bottom > 0;
      if (_editing != visible) setState(() => _editing = visible);
    },
    onPointerUp: (_) => _pointerDown = false,
    onPointerCancel: (_) => _pointerDown = false,
    child: widget.builder(!_editing, _edit),
  );
}
