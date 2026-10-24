import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chat_theme.dart';
import 'app_strings.dart';

abstract final class AppLayout {
  static bool desktop(BuildContext context) =>
      Theme.of(context).platform == TargetPlatform.windows;
  static bool split(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 840;
  static bool fullPage(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 600;
}

/// A shared surface for settings, device management and synchronization details.
class AppPanel extends StatelessWidget {
  const AppPanel({
    super.key,
    required this.title,
    required this.child,
    this.onBack,
    this.backLabel = '返回',
    this.onClose,
    this.closeLabel = '关闭',
    this.actions = const [],
    this.width = 720,
    this.height = 520,
    this.embedded = false,
    this.canClose = true,
  });

  final String title;
  final Widget child;
  final VoidCallback? onBack;
  final String backLabel;
  final VoidCallback? onClose;
  final String closeLabel;
  final List<Widget> actions;
  final double width;
  final double height;
  final bool embedded;
  final bool canClose;

  @override
  Widget build(BuildContext context) {
    final p = ChatPalette.of(context);
    if (embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: child),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.medium),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: AppSpacing.small,
                runSpacing: AppSpacing.small,
                children: actions,
              ),
            ),
        ],
      );
    }
    final header = Row(
      children: [
        if (onBack != null) ...[
          IconButton(
            tooltip: tr(context, backLabel),
            onPressed: canClose ? onBack : null,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          const SizedBox(width: 4),
        ],
        Expanded(
          child: Text(
            tr(context, title),
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        IconButton(
          tooltip: tr(context, closeLabel),
          onPressed: canClose
              ? (onClose ?? () => Navigator.pop(context))
              : null,
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    );
    final footer = actions.isEmpty
        ? null
        : Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: actions,
          );
    if (AppLayout.fullPage(context)) {
      return Dialog.fullscreen(
        backgroundColor: p.surface,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: header,
              ),
              const Divider(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.page),
                  child: child,
                ),
              ),
              if (footer != null) ...[
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  child: SizedBox(width: double.infinity, child: footer),
                ),
              ],
            ],
          ),
        ),
      );
    }
    final media = MediaQuery.of(context);
    return AlertDialog(
      title: header,
      titlePadding: const EdgeInsets.fromLTRB(
        AppSpacing.section,
        AppSpacing.large,
        AppSpacing.medium,
        0,
      ),
      contentPadding: const EdgeInsets.fromLTRB(
        AppSpacing.section,
        AppSpacing.large,
        AppSpacing.section,
        AppSpacing.page,
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      content: SizedBox(
        width: width,
        height: math.min(
          height,
          math.max(80, media.size.height - media.viewInsets.bottom - 200),
        ),
        child: child,
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actions: actions,
    );
  }
}
