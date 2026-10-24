import 'package:lanflow/ui/shared/chat_theme.dart';
import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:flutter/services.dart';

import 'package:lanflow/ui/chat/message_actions.dart';
import 'package:lanflow/ui/shared/motion.dart';

class ImageViewer extends StatefulWidget {
  const ImageViewer({
    super.key,
    required this.file,
    required this.name,
    required this.onMenu,
    this.preserveEditorFocus = false,
  });
  final File file;
  final String name;
  final void Function(Offset) onMenu;
  final bool preserveEditorFocus;
  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer>
    with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  late final AnimationController _zoomAnimation =
      AnimationController(vsync: this)..addListener(() {
        if (_zoomTween != null) {
          _transform.value = _zoomTween!.transform(
            AppMotion.curve.transform(_zoomAnimation.value),
          );
        }
      });
  Matrix4Tween? _zoomTween;
  final _imageBounds = GlobalKey();
  final _viewport = GlobalKey();
  Offset _point = Offset.zero;
  bool _chrome = true;
  bool _closing = false;
  Size? _originalSize;
  Timer? _decodeTimer;
  int _decodeSide = 3840;
  Size _available = Size.zero;
  double _density = 1;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_scheduleResolution);
    unawaited(_readDimensions());
  }

  Future<void> _readDimensions() async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromFilePath(widget.file.path);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = Size(
        descriptor.width.toDouble(),
        descriptor.height.toDouble(),
      );
      if (mounted) setState(() => _originalSize = size);
    } on Object {
      // The image widget supplies the normal unsupported/corrupt image message.
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  double get _fit {
    final size = _originalSize;
    if (size == null || _available.isEmpty) return 1;
    return math.min(
      1.0,
      math.min(_available.width / size.width, _available.height / size.height),
    );
  }

  int get _maximumDecodeSide {
    final size = _originalSize;
    if (size == null) return 3840;
    // At most 16 million decoded pixels and a 16K side, regardless of file size.
    final factor = math.min(
      1.0,
      math.sqrt(16 * 1024 * 1024 / (size.width * size.height)),
    );
    return (size.longestSide * factor).ceil().clamp(3840, 16384);
  }

  double get _maximumScale => math.max(6.0, math.min(64.0, 2 / _fit));

  void _scheduleResolution() {
    _decodeTimer?.cancel();
    _decodeTimer = Timer(const Duration(milliseconds: 100), () {
      final size = _originalSize;
      if (!mounted || size == null) return;
      final requested =
          size.longestSide *
          _fit *
          _density *
          _transform.value.getMaxScaleOnAxis();
      // Quantize zoom levels and retain the sharpest requested image while open.
      // This avoids repeated decodes and low/high resolution flicker during a pinch.
      final side = ((requested / 1024).ceil() * 1024).clamp(
        3840,
        _maximumDecodeSide,
      );
      if (side > _decodeSide) {
        final old = _provider;
        setState(() => _decodeSide = side);
        unawaited(old.evict());
      }
    });
  }

  ImageProvider get _provider => ResizeImage(
    FileImage(widget.file),
    width: _decodeSide,
    height: _decodeSide,
    policy: ResizeImagePolicy.fit,
    allowUpscaling: false,
  );

  void _close() {
    if (_closing || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    _closing = true;
    Navigator.pop(context);
  }

  void _backgroundTap(TapUpDetails details) {
    final image = _imageBounds.currentContext?.findRenderObject();
    if (image is RenderBox &&
        (Offset.zero & image.size).contains(
          image.globalToLocal(details.globalPosition),
        )) {
      return;
    }
    _close();
  }

  void _doubleTap() {
    final size = _originalSize;
    final readingScale = size != null && size.height > size.width * 4
        ? (_available.width / (size.width * _fit)).clamp(2.5, _maximumScale)
        : 2.5;
    _animateTo(
      _transform.value.getMaxScaleOnAxis() > 1.01
          ? Matrix4.identity()
          : (Matrix4.identity()
              ..translateByDouble(
                -_point.dx * (readingScale - 1),
                -_point.dy * (readingScale - 1),
                0,
                1,
              )
              ..scaleByDouble(readingScale, readingScale, 1, 1)),
    );
  }

  void _zoom(double factor) {
    final current = _transform.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(.5, _maximumScale);
    final size = MediaQuery.sizeOf(context);
    _animateTo(
      Matrix4.identity()
        ..translateByDouble(
          size.width * (1 - target) / 2,
          size.height * (1 - target) / 2,
          0,
          1,
        )
        ..scaleByDouble(target, target, 1, 1),
    );
  }

  void _animateTo(Matrix4 target) {
    final duration = AppMotion.duration(context);
    if (duration == Duration.zero) {
      _zoomAnimation.stop();
      _transform.value = target;
    } else {
      _zoomTween = Matrix4Tween(begin: _transform.value.clone(), end: target);
      _zoomAnimation.duration = duration;
      _zoomAnimation.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _decodeTimer?.cancel();
    _transform.removeListener(_scheduleResolution);
    if (_decodeSide > 3840) unawaited(_provider.evict());
    _zoomAnimation.dispose();
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final desktop = Theme.of(context).platform == TargetPlatform.windows;
    final view = MediaQuery.sizeOf(context);
    _available = Size(
      math.max(1, view.width - (desktop ? 88 : 0)),
      math.max(1, view.height - (desktop ? 160 : 0)),
    );
    _density = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 3.0);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Focus(
        autofocus: !widget.preserveEditorFocus,
        canRequestFocus: !widget.preserveEditorFocus,
        child: Scaffold(
          backgroundColor: const Color(0xFF171717),
          body: Stack(
            children: [
              Positioned.fill(
                child: Listener(
                  onPointerDown: (event) {
                    if (event.buttons == kSecondaryMouseButton) {
                      widget.onMenu(event.position);
                    }
                  },
                  child: MessageHold(
                    onHold: (position, _) => widget.onMenu(position),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: _backgroundTap,
                      child: InteractiveViewer(
                        key: _viewport,
                        transformationController: _transform,
                        onInteractionStart: (_) => _zoomAnimation.stop(),
                        minScale: .5,
                        maxScale: _maximumScale,
                        trackpadScrollCausesScale: true,
                        child: Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              vertical: desktop ? 80 : 0,
                              horizontal: desktop ? 44 : 0,
                            ),
                            child: GestureDetector(
                              key: _imageBounds,
                              onTap: () {
                                if (!desktop) {
                                  setState(() => _chrome = !_chrome);
                                }
                              },
                              onDoubleTapDown: (event) {
                                final viewport = _viewport.currentContext
                                    ?.findRenderObject();
                                if (viewport is RenderBox) {
                                  _point = viewport.globalToLocal(
                                    event.globalPosition,
                                  );
                                }
                              },
                              onDoubleTap: _doubleTap,
                              child: Image(
                                key: const ValueKey('preview-image'),
                                image: _provider,
                                gaplessPlayback: true,
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) => Text(
                                  tr(context, '暂时无法预览此图片'),
                                  style: const TextStyle(color: Colors.white70),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (_chrome)
                Positioned(
                  left: 0,
                  top: 0,
                  right: 0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapUp: _backgroundTap,
                    child: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xCC171717), Color(0x00171717)],
                        ),
                      ),
                      child: SafeArea(
                        bottom: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 28),
                          child: Row(
                            children: [
                              IconButton(
                                tooltip: tr(context, '关闭图片'),
                                onPressed: _close,
                                icon: Icon(
                                  desktop
                                      ? Icons.close_rounded
                                      : Icons.arrow_back_rounded,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  widget.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: AppTypography.secondary,
                                  ),
                                ),
                              ),
                              Builder(
                                builder: (buttonContext) => IconButton(
                                  tooltip: tr(context, '图片操作'),
                                  onPressed: () {
                                    final box =
                                        buttonContext.findRenderObject()!
                                            as RenderBox;
                                    widget.onMenu(
                                      box.localToGlobal(
                                        Offset(0, box.size.height),
                                      ),
                                    );
                                  },
                                  icon: const Icon(
                                    Icons.more_horiz,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (_chrome)
                Positioned(
                  left: 0,
                  bottom: 22,
                  right: 0,
                  child: SafeArea(
                    top: false,
                    child: Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xE6303030),
                          borderRadius: AppCorners.border,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 3,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: tr(context, '缩小'),
                                onPressed: () => _zoom(.8),
                                icon: const Icon(
                                  Icons.remove_rounded,
                                  size: 20,
                                  color: Colors.white,
                                ),
                              ),
                              TextButton(
                                onPressed: () => _animateTo(Matrix4.identity()),
                                child: Text(
                                  tr(context, desktop ? '适合窗口' : '还原'),
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: AppTypography.caption,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: tr(context, '放大'),
                                onPressed: () => _zoom(1.25),
                                icon: const Icon(
                                  Icons.add_rounded,
                                  size: 20,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
