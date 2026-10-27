import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'app_strings.dart';
import 'chat_theme.dart';

/// Only bounds the loaded image; the image's own aspect ratio sizes the tile.
class AttachmentThumbnail extends StatelessWidget {
  const AttachmentThumbnail({
    super.key,
    required this.file,
    required this.maxWidth,
    required this.maxHeight,
    this.onTap,
    this.semanticLabel,
    this.minExtent = 0,
  }) : assert(maxWidth > 0 && maxWidth < double.infinity),
       assert(maxHeight > 0 && maxHeight < double.infinity);

  final File file;
  final double maxWidth, maxHeight;
  final double minExtent;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final palette = ChatPalette.of(context);
    final density = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0);
    Widget placeholder({required bool failed}) => Container(
      width: math.min(maxWidth, 144),
      height: math.min(maxHeight, failed ? 88 : 96),
      padding: EdgeInsets.all(math.min(12, math.min(maxWidth, maxHeight) / 6)),
      color: palette.surface,
      child: LayoutBuilder(
        builder: (context, room) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                failed ? Icons.broken_image_outlined : Icons.image_outlined,
                color: palette.muted,
                size: math.min(24, math.min(room.maxWidth, room.maxHeight)),
              ),
              if (failed && room.maxWidth >= 100 && room.maxHeight >= 56) ...[
                const SizedBox(height: 8),
                Flexible(
                  child: Text(
                    tr(context, '图片 · 点击打开'),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
      child: InkWell(
        onTap: onTap,
        borderRadius: AppCorners.border,
        child: ClipRRect(
          borderRadius: AppCorners.border,
          child: _MinimumPreviewExtent(
            minExtent: minExtent,
            child: Image(
              image: ResizeImage(
                FileImage(file),
                width: (maxWidth * density).ceil().clamp(1, 1024),
                height: (maxHeight * density).ceil().clamp(1, 1536),
                policy: ResizeImagePolicy.fit,
                allowUpscaling: false,
              ),
              // No width/height or opaque loaded-image background: RenderImage
              // fits its intrinsic dimensions to the loose bounds above.
              fit: BoxFit.contain,
              semanticLabel: semanticLabel,
              filterQuality: FilterQuality.medium,
              frameBuilder: (_, child, frame, synchronous) =>
                  synchronous || frame != null
                  ? child
                  : placeholder(failed: false),
              errorBuilder: (_, _, _) => placeholder(failed: true),
            ),
          ),
        ),
      ),
    );
  }
}

// Very small images still need an independent tap target beside the receipt.
// Scale only small previews, preserving their aspect ratio and the upper bounds.
class _MinimumPreviewExtent extends SingleChildRenderObjectWidget {
  const _MinimumPreviewExtent({required this.minExtent, required super.child});
  final double minExtent;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _PreviewExtentBox(minExtent);
  @override
  void updateRenderObject(
    BuildContext context,
    _PreviewExtentBox renderObject,
  ) {
    if (renderObject.minExtent != minExtent) {
      renderObject.minExtent = minExtent;
      renderObject.markNeedsLayout();
    }
  }
}

class _PreviewExtentBox extends RenderProxyBox {
  _PreviewExtentBox(this.minExtent);
  double minExtent;
  Size _target(Size size, BoxConstraints bounds) {
    final longest = math.max(size.width, size.height);
    return longest > 0 && longest < minExtent
        ? bounds.constrainSizeAndAttemptToPreserveAspectRatio(
            size * (minExtent / longest),
          )
        : bounds.constrain(size);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _target(child!.getDryLayout(constraints.loosen()), constraints);
  @override
  void performLayout() {
    child!.layout(constraints.loosen(), parentUsesSize: true);
    final target = _target(child!.size, constraints);
    if (target != child!.size) {
      child!.layout(BoxConstraints.tight(target), parentUsesSize: true);
    }
    size = target;
  }
}
