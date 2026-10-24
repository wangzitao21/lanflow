import 'package:flutter/material.dart';
import 'chat_theme.dart';
import 'app_strings.dart';

void showAppMessage(
  BuildContext context,
  String message, {
  SnackBarAction? action,
  Duration? duration,
}) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(tr(context, message)),
        action: action,
        persist: false,
        duration:
            duration ??
            (message.contains('已删除') ||
                    message.contains('已移至回收站') ||
                    message.contains('已移入回收站')
                ? const Duration(seconds: 1)
                : action == null
                ? const Duration(milliseconds: 1500)
                : const Duration(milliseconds: 2500)),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(
          12,
          0,
          12,
          Theme.of(context).platform != TargetPlatform.windows &&
                  MediaQuery.sizeOf(context).width < 840
              ? 84
              : 12,
        ),
      ),
    );
}

class AppStatusMessage extends StatelessWidget {
  const AppStatusMessage(this.message, {super.key, this.error = true});
  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.small),
    child: Semantics(
      liveRegion: true,
      child: Text(
        tr(context, message),
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: error
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.primary,
        ),
      ),
    ),
  );
}

class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.title,
    required this.icon,
    this.description,
    this.action,
  });
  final String title;
  final IconData icon;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.section),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: ChatPalette.of(context).muted),
            const SizedBox(height: AppSpacing.large),
            Text(
              tr(context, title),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (description != null) ...[
              const SizedBox(height: AppSpacing.small),
              Text(
                tr(context, description!),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: ChatPalette.of(context).muted,
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppSpacing.large),
              action!,
            ],
          ],
        ),
      ),
    ),
  );
}
