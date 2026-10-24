import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';

import 'favorite_masonry_geometry.dart';

class FavoriteMasonry extends StatefulWidget {
  const FavoriteMasonry({
    super.key,
    required this.entries,
    required this.controller,
    required this.itemBuilder,
    this.layoutToken,
  });

  final List<FavoriteEntry> entries;
  final ScrollController controller;
  final Widget Function(BuildContext context, FavoriteEntry entry) itemBuilder;
  final Object? layoutToken;

  @override
  State<FavoriteMasonry> createState() => _FavoriteMasonryState();
}

class _FavoriteMasonryState extends State<FavoriteMasonry> {
  final _geometry = FavoriteMasonryGeometry();
  final _viewport = GlobalKey();
  final _tiles = <String, RenderBox>{};
  _ReadingAnchor? _lastAnchor, _pendingAnchor;
  ScrollPosition? _position;
  bool _frameScheduled = false;
  bool _adjusting = false;
  String? _preferredAnchor;
  int _anchorAttempts = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant FavoriteMasonry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
    if (oldWidget.layoutToken != widget.layoutToken) {
      _pendingAnchor = null;
      _lastAnchor = null;
      _preferredAnchor = null;
    } else if (!identical(oldWidget.entries, widget.entries)) {
      _pendingAnchor ??= _captureAnchor();
      _anchorAttempts = 0;
    }
    _scheduleFrame();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    _position?.isScrollingNotifier.removeListener(_scheduleFrame);
    super.dispose();
  }

  void _onScroll() {
    if (!_adjusting) _preferredAnchor = null;
    _scheduleFrame();
  }

  void _jumpTo(double offset) {
    _adjusting = true;
    try {
      widget.controller.jumpTo(offset);
    } finally {
      _adjusting = false;
    }
  }

  _ReadingAnchor? _captureAnchor() {
    if (!widget.controller.hasClients || widget.controller.offset <= .5) {
      return null;
    }
    final viewport = _viewport.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return null;
    final visible = <(String, double)>[];
    for (final entry in _tiles.entries) {
      final tile = entry.value;
      if (!tile.attached || !tile.hasSize) continue;
      final top = tile.localToGlobal(Offset.zero, ancestor: viewport).dy;
      if (top < viewport.size.height && top + tile.size.height > 0) {
        visible.add((entry.key, top));
      }
    }
    visible.sort((a, b) {
      if (a.$1 == b.$1) return 0;
      if (a.$1 == _preferredAnchor) return -1;
      if (b.$1 == _preferredAnchor) return 1;
      if ((a.$2 >= 0) != (b.$2 >= 0)) return a.$2 >= 0 ? -1 : 1;
      final order = a.$2.compareTo(b.$2);
      return order != 0 ? order : a.$1.compareTo(b.$1);
    });
    _preferredAnchor = visible.firstOrNull?.$1;
    return visible.isEmpty
        ? null
        : _ReadingAnchor(widget.controller.offset, visible);
  }

  void _scheduleFrame() {
    if (_frameScheduled || !mounted) return;
    _frameScheduled = true;
    WidgetsBinding.instance.ensureVisualUpdate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _frameScheduled = false;
      if (!mounted || !widget.controller.hasClients) return;
      final position = widget.controller.position;
      if (!identical(position, _position)) {
        _position?.isScrollingNotifier.removeListener(_scheduleFrame);
        _position = position;
        position.isScrollingNotifier.addListener(_scheduleFrame);
      }
      final pending = _pendingAnchor;
      if (pending != null && !position.isScrollingNotifier.value) {
        _restoreAnchor(pending);
      }
      _lastAnchor = _captureAnchor();
    });
  }

  void _restoreAnchor(_ReadingAnchor pending) {
    final viewport = _viewport.currentContext?.findRenderObject();
    if (viewport is! RenderBox) return;
    final position = widget.controller.position;
    for (final (id, oldTop) in pending.items) {
      final tile = _tiles[id];
      if (tile == null || !tile.attached || !tile.hasSize) continue;
      final top = tile.localToGlobal(Offset.zero, ancestor: viewport).dy;
      final expected = oldTop - (position.pixels - pending.scrollOffset);
      final target = (position.pixels + top - expected).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      _pendingAnchor = null;
      if ((target - position.pixels).abs() > .1) {
        _jumpTo(target);
        _scheduleFrame();
      }
      return;
    }
    // A larger insertion may put the old reference just outside the lazy
    // viewport. Seek using cached extents, then refine against its real box.
    if (_anchorAttempts++ < 2) {
      for (final (id, oldTop) in pending.items) {
        final offset = _geometry.offsetOf(id);
        if (offset == null) continue;
        final target = (offset - oldTop).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        _jumpTo(target);
        _pendingAnchor = _ReadingAnchor(target, pending.items);
        _scheduleFrame();
        return;
      }
    }
    _pendingAnchor = null;
  }

  void _measured(String id, RenderBox tile, double? previousHeight) {
    _geometry.measure(id, tile.size.height);
    if (previousHeight != null &&
        (previousHeight - tile.size.height).abs() > .1) {
      _pendingAnchor ??= _lastAnchor;
    }
    _scheduleFrame();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final minimum = scale > 1.15
          ? 230.0
          : bounds.maxWidth < 600
          ? 164.0
          : 248.0;
      const gap = FavoriteMasonryGeometry.gap;
      final count = ((bounds.maxWidth + gap) / (minimum + gap)).floor().clamp(
        1,
        4,
      );
      final width = (bounds.maxWidth - gap * (count - 1)) / count;
      _geometry.arrange(
        widget.entries,
        count,
        width,
        scale,
        widget.layoutToken,
      );
      _scheduleFrame();
      return SizedBox(
        key: _viewport,
        child: CustomScrollView(
          key: const PageStorageKey('favorites-list'),
          controller: widget.controller,
          scrollCacheExtent: const ScrollCacheExtent.pixels(240),
          semanticChildCount: widget.entries.length,
          slivers: [
            SliverCrossAxisGroup(
              slivers: [
                for (var column = 0; column < count; column++) ...[
                  if (column > 0)
                    const SliverConstrainedCrossAxis(
                      maxExtent: gap,
                      sliver: SliverToBoxAdapter(child: SizedBox.shrink()),
                    ),
                  SliverList(
                    key: ValueKey('favorites-column-$column-of-$count'),
                    delegate: _ColumnDelegate(
                      _geometry.columns[column],
                      _geometry.globalIndices,
                      (context, entry) => _MeasuredTile(
                        key: ValueKey(entry.id),
                        onAttach: (box) => _tiles[entry.id] = box,
                        onDetach: (box) {
                          if (identical(_tiles[entry.id], box)) {
                            _tiles.remove(entry.id);
                          }
                        },
                        onLayout: (box, previous) =>
                            _measured(entry.id, box, previous),
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: gap),
                          child: widget.itemBuilder(context, entry),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 4)),
          ],
        ),
      );
    },
  );
}

class _ReadingAnchor {
  const _ReadingAnchor(this.scrollOffset, this.items);
  final double scrollOffset;
  final List<(String, double)> items;
}

class _ColumnDelegate extends SliverChildBuilderDelegate {
  _ColumnDelegate(
    this.column,
    Map<String, int> globalIndices,
    Widget Function(BuildContext, FavoriteEntry) builder,
  ) : super(
        (context, row) => builder(context, column.entries[row]),
        childCount: column.entries.length,
        addAutomaticKeepAlives: false,
        findChildIndexCallback: (key) =>
            key is ValueKey<String> ? column.indices[key.value] : null,
        semanticIndexCallback: (_, row) =>
            globalIndices[column.entries[row].id],
      );
  final FavoriteMasonryColumn column;

  @override
  double estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) => trailingScrollOffset + column.remainingAfter(lastIndex);
}

class _MeasuredTile extends SingleChildRenderObjectWidget {
  const _MeasuredTile({
    super.key,
    required this.onAttach,
    required this.onDetach,
    required this.onLayout,
    required super.child,
  });
  final void Function(RenderBox) onAttach, onDetach;
  final void Function(RenderBox, double?) onLayout;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MeasuredTileBox(onAttach, onDetach, onLayout);
  @override
  void updateRenderObject(BuildContext context, _MeasuredTileBox renderObject) {
    renderObject
      ..onAttach = onAttach
      ..onDetach = onDetach
      ..onLayout = onLayout;
  }
}

class _MeasuredTileBox extends RenderProxyBox {
  _MeasuredTileBox(this.onAttach, this.onDetach, this.onLayout);
  void Function(RenderBox) onAttach, onDetach;
  void Function(RenderBox, double?) onLayout;
  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    onAttach(this);
  }

  @override
  void detach() {
    onDetach(this);
    super.detach();
  }

  @override
  void performLayout() {
    final previous = hasSize ? size.height : null;
    super.performLayout();
    onLayout(this, previous);
  }
}
