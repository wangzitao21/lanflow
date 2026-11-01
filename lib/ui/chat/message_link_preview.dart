import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:lanflow/core/network/link_preview.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/search_text.dart';

class MessageLinkPreview extends StatefulWidget {
  const MessageLinkPreview({
    super.key,
    required this.text,
    required this.fallback,
    required this.onLink,
    this.highlightQuery = '',
    this.service,
  });
  final String text, highlightQuery;
  final Widget fallback;
  final void Function(String) onLink;
  final LinkPreviewService? service;
  @override
  State<MessageLinkPreview> createState() => _MessageLinkPreviewState();
}

class _MessageLinkPreviewState extends State<MessageLinkPreview> {
  Uri? _url;
  Future<LinkPreview?>? _preview;
  LinkPreviewService get service => widget.service ?? LinkPreviewService.shared;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MessageLinkPreview old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.service != widget.service) _load();
  }

  void _load() {
    _url = firstMessageLink(widget.text);
    _preview = _url == null ? null : service.load(_url!);
  }

  @override
  Widget build(BuildContext context) {
    if (_preview == null) return widget.fallback;
    return FutureBuilder<LinkPreview?>(
      future: _preview,
      builder: (context, snapshot) {
        final preview = snapshot.connectionState == ConnectionState.done
            ? snapshot.data
            : null;
        if (preview == null) return widget.fallback;
        final text = widget.text.trim();
        final onlyLink =
            text == _url.toString() || 'https://$text' == _url.toString();
        final palette = ChatPalette.of(context);
        final card = InkWell(
          key: const ValueKey('message-link-card'),
          onTap: () => widget.onLink(_url.toString()),
          child: SizedBox(
            width: 340,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                HighlightedText(
                  preview.title,
                  query: widget.highlightQuery,
                  maxLines: 3,
                  style: TextStyle(
                    fontSize: AppTypography.body,
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        preview.description.isEmpty
                            ? _url!.host
                            : preview.description,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: palette.muted, height: 1.4),
                      ),
                    ),
                    if (preview.image != null) ...[
                      const SizedBox(width: 12),
                      _PreviewImage(url: preview.image!, service: service),
                    ],
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Icon(Icons.link, size: 16, color: palette.muted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        preview.source,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.muted,
                          fontSize: AppTypography.caption,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
        if (onlyLink) return card;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [widget.fallback, const Divider(height: 24), card],
        );
      },
    );
  }
}

class _PreviewImage extends StatefulWidget {
  const _PreviewImage({required this.url, required this.service});
  final Uri url;
  final LinkPreviewService service;
  @override
  State<_PreviewImage> createState() => _PreviewImageState();
}

class _PreviewImageState extends State<_PreviewImage> {
  late Future<Uint8List?> _bytes = widget.service.loadImage(widget.url);
  @override
  void didUpdateWidget(_PreviewImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.service != widget.service) {
      _bytes = widget.service.loadImage(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _bytes,
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes == null) return const SizedBox.shrink();
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.memory(
          bytes,
          width: 72,
          height: 72,
          cacheWidth: 180,
          fit: BoxFit.cover,
          excludeFromSemantics: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      );
    },
  );
}
