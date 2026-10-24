import 'package:flutter/material.dart';
import 'app_strings.dart';

typedef ShowAppDialog =
    Future<T?> Function<T>({
      required BuildContext context,
      required WidgetBuilder builder,
    });

class AppConfirmDialog extends StatelessWidget {
  const AppConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.destructive = true,
  });
  final String title, message, confirmLabel;
  final bool destructive;

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(tr(context, title)),
    content: Text(tr(context, message)),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: Text(tr(context, '取消')),
      ),
      FilledButton(
        style: destructive
            ? FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              )
            : null,
        onPressed: () => Navigator.pop(context, true),
        child: Text(tr(context, confirmLabel)),
      ),
    ],
  );
}
