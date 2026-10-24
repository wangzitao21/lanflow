import 'package:lanflow/core/inbox/inbox_models.dart';

class MessagePresentation {
  const MessagePresentation({
    required this.showTime,
    required this.showIdentity,
    required this.showStatus,
  });
  final bool showTime, showIdentity, showStatus;

  factory MessagePresentation.at(
    List<InboxEntry> entries,
    int index, {
    bool focused = false,
  }) {
    final current = entries[index].item;
    final older = index + 1 < entries.length ? entries[index + 1].item : null;
    bool sameDay(InboxItem item) {
      final left = current.createdAt.toLocal();
      final right = item.createdAt.toLocal();
      return left.year == right.year &&
          left.month == right.month &&
          left.day == right.day;
    }

    return MessagePresentation(
      showTime:
          focused ||
          older == null ||
          !sameDay(older) ||
          current.createdAt.difference(older.createdAt) >=
              const Duration(minutes: 5),
      showIdentity: true,
      showStatus: true,
    );
  }
}
