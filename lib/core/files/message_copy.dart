import 'package:lanflow/core/inbox/inbox_models.dart';

String mergedMessageText(
  Iterable<InboxEntry> selected, {
  bool numbered = false,
}) {
  final entries = selected.toList()
    ..sort((a, b) {
      final time = a.item.createdAt.compareTo(b.item.createdAt);
      return time == 0 ? a.item.id.compareTo(b.item.id) : time;
    });
  return entries.indexed
      .map((value) {
        final (index, entry) = value;
        final item = entry.item;
        final content = [
          if (item.isFile) item.name,
          if (item.text.isNotEmpty) item.text,
        ].join('\n');
        return numbered ? '${index + 1}. $content' : content;
      })
      .join('\n\n');
}
