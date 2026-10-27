import 'dart:async';

import 'package:flutter/material.dart';
import 'chat_theme.dart';
import 'app_strings.dart';

final _messageTokens = Expando<Object>();

void showAppMessage(
  BuildContext context,
  String message, {
  SnackBarAction? action,
  Duration? duration,
}) {
  final messenger = ScaffoldMessenger.of(context);
  final lifetime = duration == null || duration > const Duration(seconds: 1)
      ? const Duration(seconds: 1)
      : duration;
  final token = Object();
  _messageTokens[messenger] = token;
  messenger
    ..removeCurrentSnackBar()
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: TransientNotice(
          key: UniqueKey(),
          duration: lifetime,
          onDismiss: () {
            if (messenger.mounted &&
                identical(_messageTokens[messenger], token)) {
              messenger.removeCurrentSnackBar();
            }
          },
          child: Text(tr(context, message)),
        ),
        action: action,
        persist: false,
        duration: lifetime,
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
      snackBarAnimationStyle: AnimationStyle.noAnimation,
    );
}

class TransientNotice extends StatefulWidget {
  const TransientNotice({
    super.key,
    required this.child,
    this.onDismiss,
    this.duration = const Duration(seconds: 1),
  });
  final Widget child;
  final VoidCallback? onDismiss;
  final Duration duration;

  @override
  State<TransientNotice> createState() => _TransientNoticeState();
}

class _TransientNoticeState extends State<TransientNotice> {
  Timer? _timer;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.duration, () {
      if (!mounted) return;
      setState(() => _visible = false);
      widget.onDismiss?.call();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _visible ? widget.child : const SizedBox.shrink();
}

class AppStatusMessage extends StatelessWidget {
  const AppStatusMessage(this.message, {super.key, this.error = true});
  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) => error
      ? _content(context)
      : TransientNotice(key: ValueKey(message), child: _content(context));

  Widget _content(BuildContext context) => Padding(
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
