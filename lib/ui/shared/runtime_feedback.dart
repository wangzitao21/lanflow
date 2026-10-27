import 'package:flutter/material.dart';
import 'app_feedback.dart';
import 'chat_theme.dart';
import 'app_strings.dart';

class RuntimeFeedback extends StatelessWidget {
  const RuntimeFeedback({
    super.key,
    required this.child,
    required this.changing,
    required this.progress,
    required this.onDismiss,
    this.notice,
  });
  final Widget child;
  final bool changing;
  final String progress;
  final String? notice;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final palette = ChatPalette.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(
          excluding: changing,
          child: IgnorePointer(ignoring: changing, child: child),
        ),
        if (notice != null && !changing)
          Positioned(
            left: AppSpacing.large,
            right: AppSpacing.large,
            bottom: AppSpacing.large,
            child: TransientNotice(
              key: ValueKey(notice),
              onDismiss: onDismiss,
              child: SafeArea(
                child: Material(
                  key: const ValueKey('runtime-notice'),
                  elevation: 4,
                  color: palette.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: AppCorners.border,
                    side: BorderSide(color: palette.divider),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              tr(context, notice!),
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.small),
                        Semantics(
                          label: tr(context, '关闭'),
                          child: IconButton(
                            onPressed: onDismiss,
                            icon: const Icon(Icons.close, size: 18),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (changing)
          Positioned.fill(
            child: Material(
              key: const ValueKey('storage-migration-overlay'),
              color: palette.canvas,
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpacing.section),
                    child: Semantics(
                      liveRegion: true,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: AppSpacing.section),
                          Text(
                            tr(context, progress),
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: AppSpacing.small),
                          Text(
                            tr(context, '完成前请保持应用打开'),
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
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
}

class StartupFailure extends StatefulWidget {
  const StartupFailure({super.key, required this.onRetry});
  final Future<void> Function() onRetry;

  @override
  State<StartupFailure> createState() => _StartupFailureState();
}

class _StartupFailureState extends State<StartupFailure> {
  bool _retrying = false;
  bool _failed = false;
  Future<void> _retry() async {
    if (_retrying) return;
    setState(() {
      _retrying = true;
      _failed = false;
    });
    try {
      await widget.onRetry();
    } on Object {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: AppEmptyState(
        title: '暂时无法打开存储位置',
        icon: Icons.folder_off_outlined,
        description: _failed
            ? '仍无法访问存储位置，请检查磁盘连接和访问权限。原数据不会被重置。'
            : '请连接原来的磁盘并检查访问权限。原数据不会被重置。',
        action: FilledButton(
          onPressed: _retrying ? null : _retry,
          child: Text(tr(context, _retrying ? '重试中…' : '重试')),
        ),
      ),
    ),
  );
}
