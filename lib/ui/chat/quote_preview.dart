import 'dart:io';
import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/app_strings.dart';

class QuotePreview extends StatelessWidget {
  const QuotePreview({
    super.key,
    required this.quote,
    this.onClose,
    this.onTap,
    this.draft = false,
    this.mobile = false,
    this.source,
    this.image,
  });
  final MessageQuote quote;
  final VoidCallback? onClose, onTap;
  final bool draft, mobile;
  final InboxItem? source;
  final File? image;

  String _summary(BuildContext context) {
    if (source?.isFile == true) {
      return switch (source!.kind) {
        MessageKind.image => '[${tr(context, '图片')}]',
        MessageKind.video => '[${tr(context, '视频')}]',
        _ => '[${tr(context, '文件')}] ${source!.name}',
      };
    }
    if (quote.text.startsWith('[image] ')) return '[${tr(context, '图片')}]';
    if (quote.text.startsWith('[video] ')) return '[${tr(context, '视频')}]';
    if (quote.text.startsWith('[file] ')) {
      return '[${tr(context, '文件')}] ${quote.text.substring(7)}';
    }
    return quote.text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  @override
  Widget build(BuildContext context) {
    final palette = ChatPalette.of(context);
    final compact = draft && !mobile;
    final stretch = draft && mobile;
    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            key: ValueKey(
              draft ? 'composer-quote' : 'message-quote-${quote.id}',
            ),
            margin: EdgeInsets.only(top: draft ? 0 : 6),
            padding: compact
                ? const EdgeInsets.only(left: 10)
                : const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: compact ? null : palette.muted.withValues(alpha: .11),
              borderRadius: compact ? null : BorderRadius.circular(4),
              border: compact
                  ? Border(left: BorderSide(color: palette.divider, width: 2))
                  : null,
            ),
            child: Row(
              mainAxisSize: stretch ? MainAxisSize.max : MainAxisSize.min,
              children: [
                Flexible(
                  fit: stretch ? FlexFit.tight : FlexFit.loose,
                  child: Text(
                    '${quote.name}：${_summary(context)}',
                    key: ValueKey(
                      draft ? 'composer-quote-label' : 'message-quote-label',
                    ),
                    maxLines: draft ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: draft ? 13 : 12,
                      height: 1.4,
                      color: palette.muted,
                    ),
                  ),
                ),
                if (image != null) ...[
                  const SizedBox(width: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: Image.file(
                      image!,
                      key: ValueKey('quote-thumbnail-${quote.id}'),
                      width: draft ? 24 : 32,
                      height: draft ? 24 : 32,
                      fit: BoxFit.cover,
                      cacheWidth: 96,
                      errorBuilder: (_, _, _) => Icon(
                        Icons.image_outlined,
                        size: draft ? 24 : 32,
                        color: palette.muted,
                      ),
                    ),
                  ),
                ],
                if (onClose != null) ...[
                  const SizedBox(width: 6),
                  IconButton(
                    key: const ValueKey('cancel-composer-quote'),
                    tooltip: tr(context, '取消引用'),
                    onPressed: onClose,
                    icon: const Icon(Icons.cancel_rounded, size: 16),
                    color: palette.muted.withValues(alpha: .8),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
