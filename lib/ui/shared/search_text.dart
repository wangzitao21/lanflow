import 'package:flutter/material.dart';
import 'chat_theme.dart';

RegExp? searchPattern(String query) => query.trim().isEmpty
    ? null
    : RegExp(RegExp.escape(query.trim()), caseSensitive: false, unicode: true);

List<TextSpan> highlightMatches(
  TextSpan span,
  String query,
  ChatPalette palette,
) => highlightTextSpans([span], query, palette);

List<TextSpan> highlightTextSpans(
  List<TextSpan> spans,
  String query,
  ChatPalette palette,
) {
  final pattern = searchPattern(query);
  if (pattern == null) return spans;
  final combined = spans.map((span) => span.text ?? '').join();
  final matches = pattern.allMatches(combined).toList();
  if (matches.isEmpty) return spans;
  final result = <TextSpan>[];
  var offset = 0;
  var firstMatch = 0;
  for (final span in spans) {
    final text = span.text ?? '';
    final end = offset + text.length;
    TextSpan part(int start, int finish, bool highlighted) => TextSpan(
      text: text.substring(start, finish),
      style: highlighted
          ? (span.style ?? const TextStyle()).copyWith(
              color: palette.onSearchHighlight,
              backgroundColor: palette.searchHighlight,
            )
          : span.style,
      recognizer: span.recognizer,
      mouseCursor: span.mouseCursor,
    );
    while (firstMatch < matches.length && matches[firstMatch].end <= offset) {
      firstMatch++;
    }
    var position = 0;
    for (
      var index = firstMatch;
      index < matches.length && matches[index].start < end;
      index++
    ) {
      final match = matches[index];
      final start = (match.start - offset).clamp(0, text.length);
      final finish = (match.end - offset).clamp(0, text.length);
      if (position < start) result.add(part(position, start, false));
      if (finish > start) result.add(part(start, finish, true));
      position = finish;
    }
    if (position < text.length) result.add(part(position, text.length, false));
    offset = end;
  }
  return result;
}

String searchExcerpt(String text, String query) {
  final value = text.replaceAll(RegExp(r'\s+'), ' ');
  final match = searchPattern(query)?.firstMatch(value);
  var start = ((match?.start ?? 0) - 36).clamp(0, value.length);
  var end = ((match?.end ?? 0) + 100).clamp(start, value.length);
  // Keep UTF-16 surrogate pairs intact at snippet boundaries.
  if (start > 0 && (value.codeUnitAt(start) & 0xFC00) == 0xDC00) start--;
  if (end > 0 &&
      end < value.length &&
      (value.codeUnitAt(end - 1) & 0xFC00) == 0xD800) {
    end++;
  }
  return '${start > 0 ? '…' : ''}${value.substring(start, end)}${end < value.length ? '…' : ''}';
}

class HighlightedText extends StatelessWidget {
  const HighlightedText(
    this.text, {
    super.key,
    required this.query,
    this.style,
    this.maxLines,
  });
  final String text, query;
  final TextStyle? style;
  final int? maxLines;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: highlightMatches(
        TextSpan(text: text),
        query,
        ChatPalette.of(context),
      ),
    ),
    style: style,
    maxLines: maxLines,
    overflow: maxLines == null ? null : TextOverflow.ellipsis,
  );
}
