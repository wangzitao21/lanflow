import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/search_text.dart';

class MessageText extends StatefulWidget {
  const MessageText({
    super.key,
    required this.text,
    required this.onLink,
    this.outgoing = false,
    this.fontSize = ChatMetrics.messageFontSize,
    this.selectable = false,
    this.onSelectionChanged,
    this.highlightQuery = '',
  });
  final String text;
  final String highlightQuery;
  final void Function(String) onLink;
  final bool outgoing;
  final double fontSize;
  final bool selectable;
  final ValueChanged<String?>? onSelectionChanged;
  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  final _recognizers = <TapGestureRecognizer>[];
  List<TextSpan> _spans = [];
  Color _linkColor = const Color(0xFF245D91);
  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(MessageText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text ||
        old.outgoing != widget.outgoing ||
        old.selectable != widget.selectable) {
      _parse();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final color = widget.outgoing
        ? ChatPalette.of(context).outgoingLink
        : ChatPalette.of(context).link;
    if (_linkColor != color) {
      _linkColor = color;
      _parse();
    }
  }

  void _parse() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
    final spans = <TextSpan>[];
    TextSpan plain(String text) => TextSpan(
      text: text,
      mouseCursor: widget.selectable
          ? SystemMouseCursors.text
          : MouseCursor.defer,
    );
    var position = 0;
    for (final match in RegExp(
      r'''(?:https?://|www\.)[^\s<>"\u3000]+''',
      caseSensitive: false,
    ).allMatches(widget.text)) {
      var url = match.group(0)!;
      url = url.replaceFirst(RegExp(r'[。，、；：！？,.!;:）)\]】]+$'), '');
      final parsed = Uri.tryParse(
        url.startsWith('www.') ? 'https://$url' : url,
      );
      if (parsed == null || parsed.host.isEmpty) continue;
      if (match.start > position) {
        spans.add(plain(widget.text.substring(position, match.start)));
      }
      final recognizer = TapGestureRecognizer()
        ..onTap = () => widget.onLink(parsed.toString());
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: url,
          style: TextStyle(
            color: _linkColor,
            decoration: TextDecoration.underline,
            decorationColor: _linkColor.withValues(alpha: .45),
          ),
          recognizer: recognizer,
          mouseCursor: SystemMouseCursors.click,
        ),
      );
      position = match.start + url.length;
    }
    if (position < widget.text.length) {
      spans.add(plain(widget.text.substring(position)));
    }
    _spans = spans;
  }

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget text = Text.rich(
      TextSpan(
        children: highlightTextSpans(
          _spans,
          widget.highlightQuery,
          ChatPalette.of(context),
        ),
      ),
      textWidthBasis: TextWidthBasis.longestLine,
      style: TextStyle(
        fontSize: widget.fontSize,
        height: ChatMetrics.messageLineHeight,
        letterSpacing: 0,
        fontWeight: FontWeight.w400,
        color: widget.outgoing
            ? ChatPalette.of(context).outgoingText
            : Theme.of(context).colorScheme.onSurface,
      ),
    );
    // A message consisting of one link has a continuous click target,
    // including inter-glyph boundaries and the line's leading space.
    if (_spans.length == 1 && _recognizers.length == 1) {
      text = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _recognizers.single.onTap,
        child: text,
      );
    }
    if (!widget.selectable) return text;
    return MouseRegion(
      cursor: SystemMouseCursors.text,
      child: SelectionArea(
        selectionControls: desktopTextSelectionHandleControls,
        // Message actions are provided by the shared desktop context menu.
        contextMenuBuilder: (_, _) => const SizedBox.shrink(),
        onSelectionChanged: (selection) =>
            widget.onSelectionChanged?.call(selection?.plainText),
        child: text,
      ),
    );
  }
}
