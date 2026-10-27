import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/platform/title_order.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/shared/app_feedback.dart';
import 'package:lanflow/ui/shared/app_dialogs.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';
import 'package:lanflow/ui/shared/app_strings.dart';

import 'favorite_actions.dart';
import 'favorite_card.dart';
import 'favorite_detail.dart';
import 'favorite_masonry.dart';
import 'favorite_list_tile.dart';
import 'favorite_results.dart';
import 'favorite_view_controls.dart';
import 'message_actions.dart';

class FavoritesPanel extends StatefulWidget {
  const FavoritesPanel({
    super.key,
    required this.inbox,
    this.onLocate,
    this.onBackHandlerChanged,
    this.titleOrder,
    this.embedded = false,
  });
  final InboxController inbox;
  final ValueChanged<InboxEntry>? onLocate;
  final ValueChanged<VoidCallback?>? onBackHandlerChanged;
  final bool embedded;
  final TitleOrder? titleOrder;

  @override
  State<FavoritesPanel> createState() => _FavoritesPanelState();
}

class _FavoritesPanelState extends State<FavoritesPanel> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _selected = <String>{};
  final _images = <String, _FavoriteImageRequest>{};
  late final _titleOrder = widget.titleOrder ?? TitleOrder();
  final _viewOffsets = <String, double>{};
  Map<String, FavoriteEntry> _byId = {};
  List<String> _titles = [];
  List<String>? _requestedTitles;
  List<String>? _readyTitles;
  Map<String, int>? _titleRanks;
  int _titleRanksRevision = 0;
  int? _preferencesRevision;
  int _pinsKey = 0;
  bool _ordering = false;
  int? _imagesRevision;
  late final _actions = FavoriteActions(widget.inbox);
  Timer? _searchTimer;
  String _query = '';
  bool _busy = false;
  bool _selecting = false;
  String? _error;
  Object? _resultsKey;
  List<FavoriteEntry> _results = [];
  FavoriteEntry? _opened;
  final _detailKey = GlobalKey<FavoriteDetailState>();

  @override
  void dispose() {
    widget.onBackHandlerChanged?.call(null);
    _searchTimer?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _searchChanged(String value) {
    _searchTimer?.cancel();
    void apply() {
      if (!mounted) return;
      setState(() {
        _query = value.trim().toLowerCase();
        _selected.clear();
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }

    if (value.trim().isEmpty) {
      apply();
    } else {
      _searchTimer = Timer(const Duration(milliseconds: 100), apply);
    }
  }

  List<FavoriteEntry> _entries() {
    final favorites = widget.inbox.favoriteEntries;
    final revision = widget.inbox.store.favoritesRevision;
    final preferences = widget.inbox.favoritePreferences;
    if (_imagesRevision != revision) {
      _imagesRevision = revision;
      _byId = {for (final entry in favorites) entry.id: entry};
      _images.removeWhere(
        (id, image) =>
            !_byId.containsKey(id) || _byId[id]!.item.digest != image.digest,
      );
      _selected.removeWhere((id) => !_byId.containsKey(id));
      final titles = favorites
          .map(
            (entry) => TitleOrder.label(
              entry.item.isFile ? entry.item.name : entry.item.text,
            ),
          )
          .toList();
      if (!listEquals(titles, _titles)) _titles = titles;
    }
    if (_preferencesRevision != widget.inbox.favoritePreferencesRevision) {
      _preferencesRevision = widget.inbox.favoritePreferencesRevision;
      _pinsKey = Object.hashAllUnordered(
        preferences.pinned.entries.map(
          (entry) => Object.hash(entry.key, entry.value),
        ),
      );
    }
    final byTitle =
        preferences.sort == 'titleAsc' || preferences.sort == 'titleDesc';
    if (byTitle && !identical(_readyTitles, _titles)) _prepareTitleOrder();
    final key = (
      revision,
      _query,
      preferences.filter,
      preferences.onlyPinned,
      preferences.sort,
      _pinsKey,
      _titleRanksRevision,
    );
    if (_resultsKey != key) {
      _resultsKey = key;
      _results = favoriteResults(
        favorites,
        preferences,
        _query,
        titleRanks: identical(_readyTitles, _titles) ? _titleRanks : null,
        previous: _results,
      );
      final visible = _results.map((entry) => entry.id).toSet();
      _selected.removeWhere((id) => !visible.contains(id));
    }
    return _results;
  }

  void _prepareTitleOrder() {
    if (identical(_requestedTitles, _titles)) return;
    final requested = _requestedTitles = _titles;
    _ordering = true;
    unawaited(
      _titleOrder
          .ranks(requested)
          .then(
            (ranks) {
              if (!mounted || !identical(requested, _titles)) return;
              setState(() {
                _readyTitles = requested;
                _titleRanks = ranks;
                _titleRanksRevision++;
                _ordering = false;
              });
            },
            onError: (Object error) {
              if (!mounted || !identical(requested, _titles)) return;
              setState(() {
                _ordering = false;
                final sort = widget.inbox.favoritePreferences.sort;
                if (sort == 'titleAsc' || sort == 'titleDesc') {
                  _error = '排序未完成，请重试';
                }
              });
            },
          ),
    );
  }

  Future<File>? _imageFor(FavoriteEntry entry) {
    if (entry.item.kind != MessageKind.image) return null;
    final previous = _images[entry.id];
    final revision = widget.inbox.store.favoritesRevision;
    if (previous != null &&
        (!previous.failed || previous.revision == revision)) {
      return previous.future;
    }
    final request = _FavoriteImageRequest(entry.item.digest, revision);
    request.future = widget.inbox
        .favoriteFileForExport(entry)
        .then(
          (file) => file,
          onError: (Object error, StackTrace stack) {
            request.failed = true;
            Error.throwWithStackTrace(error, stack);
          },
        );
    _images[entry.id] = request;
    return request.future;
  }

  Future<void> _preferences(
    FavoritePreferences value, {
    bool resetScroll = true,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      if (!_ordering) _requestedTitles = null;
    });
    try {
      await widget.inbox.setFavoritePreferences(value);
      if (mounted && resetScroll && _scroll.hasClients) _scroll.jumpTo(0);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = userError(error, fallback: '收藏偏好保存失败，请重试'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _layout(String layout) async {
    final preferences = widget.inbox.favoritePreferences;
    if (_busy || preferences.layout == layout) return;
    if (_scroll.hasClients) _viewOffsets[preferences.layout] = _scroll.offset;
    await _preferences(
      preferences.copyWith(layout: layout),
      resetScroll: false,
    );
    if (!mounted || widget.inbox.favoritePreferences.layout != layout) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(
          (_viewOffsets[layout] ?? 0).clamp(
            0,
            _scroll.position.maxScrollExtent,
          ),
        );
      }
    });
  }

  Future<void> _pin(List<FavoriteEntry> entries, bool pinned) =>
      _perform(() async {
        await widget.inbox.setFavoritesPinned(
          entries.map((entry) => entry.id),
          pinned,
        );
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
        return true;
      }, pinned ? '已置顶' : '已取消置顶');

  void _toggle(String id) {
    if (_busy) return;
    setState(() {
      _selecting = true;
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  Future<void> _view(FavoriteEntry entry) async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _opened = entry);
    widget.onBackHandlerChanged?.call(_requestDetailBack);
  }

  void _requestDetailBack() => _detailKey.currentState?.requestBack();

  void _back() {
    if (!mounted) return;
    setState(() => _opened = null);
    widget.onBackHandlerChanged?.call(null);
  }

  Future<void> _locate(FavoriteEntry entry) async {
    try {
      final original = await widget.inbox.store.loadEntry(
        entry.originalMessageId,
      );
      if (mounted && original != null) widget.onLocate?.call(original);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = userError(error, fallback: '聊天记录加载失败，请重试'));
      }
    }
  }

  Future<bool> _delete(List<FavoriteEntry> entries) async {
    if (_busy || entries.isEmpty) return false;
    {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AppConfirmDialog(
          title: tr(context, '删除 {count} 项收藏？', {'count': entries.length}),
          confirmLabel: tr(context, '删除收藏'),
          message: tr(context, '这会删除原消息及其收藏，并在联网后同步删除其他设备上的同一消息。'),
        ),
      );
      if (confirmed != true || !mounted) return false;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final ids = entries.map((entry) => entry.id).toList();
    try {
      await widget.inbox.deleteFavorites(ids);
      if (mounted) {
        setState(() {
          _selected.removeAll(ids);
          if (_selected.isEmpty) _selecting = false;
        });
      }
      return true;
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = userError(error, fallback: '收藏操作失败，请重试'));
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _perform(
    Future<bool> Function() operation,
    String success,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (await operation() && mounted) showAppMessage(context, success);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = userError(error, fallback: '收藏操作失败，请重试'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _menu(FavoriteEntry entry, Offset point) async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final originalExists = widget.inbox.store.originalExists(entry);
    final pinned = widget.inbox.favoritePreferences.pinned.containsKey(
      entry.id,
    );
    final action = await showMessageActions(
      context: context,
      anchor: Rect.fromLTWH(point.dx, point.dy, 1, 1),
      menuKey: const ValueKey('favorite-action-menu'),
      animate: false,
      actions: [
        const MessageAction('view', '查看详情', Icons.open_in_new_outlined),
        MessageAction('pin', pinned ? '取消置顶' : '置顶', Icons.push_pin_outlined),
        MessageAction(
          'copy',
          entry.item.isFile ? '复制文件名' : '复制文字',
          Icons.content_copy_outlined,
        ),
        if (entry.item.isFile)
          const MessageAction('save', '另存为', Icons.save_alt_outlined),
        const MessageAction('export', '导出', Icons.archive_outlined),
        if (originalExists && widget.onLocate != null)
          const MessageAction(
            'locate',
            '定位原消息',
            Icons.chat_bubble_outline_rounded,
          ),
        const MessageAction(
          'delete',
          '删除收藏',
          Icons.delete_outline_rounded,
          destructive: true,
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'view':
        await _view(entry);
      case 'pin':
        await _pin([entry], !pinned);
      case 'copy':
        await _perform(() async {
          await _actions.copy(entry);
          return true;
        }, '已复制');
      case 'save':
        await _perform(() => _actions.saveFile(entry), '文件已保存');
      case 'export':
        await _perform(() => _actions.export([entry]), '已导出收藏');
      case 'locate':
        _locate(entry);
      case 'delete':
        await _delete([entry]);
    }
  }

  Widget _item(
    BuildContext context,
    FavoriteEntry entry, {
    required bool list,
  }) {
    final pinned = widget.inbox.favoritePreferences.pinned.containsKey(
      entry.id,
    );
    if (list) {
      return FavoriteListTile(
        key: ValueKey(entry.id),
        entry: entry,
        pinned: pinned,
        query: _query,
        selected: _selected.contains(entry.id),
        selecting: _selecting,
        enabled: !_busy,
        imageFile: _imageFor(entry),
        onOpen: () => unawaited(_view(entry)),
        onToggle: () => _toggle(entry.id),
        onMenu: (point) => unawaited(_menu(entry, point)),
        onDelete: () => unawaited(_delete([entry])),
      );
    }
    return FavoriteCard(
      key: ValueKey(entry.id),
      id: entry.id,
      item: entry.item,
      savedAt: entry.savedAt,
      source: entry.item.originName,
      pinned: pinned,
      query: _query,
      selected: _selected.contains(entry.id),
      selecting: _selecting,
      enabled: !_busy,
      imageFile: _imageFor(entry),
      onOpen: () => unawaited(_view(entry)),
      onToggle: () => _toggle(entry.id),
      onMenu: (point) => unawaited(_menu(entry, point)),
      onDelete: () => unawaited(_delete([entry])),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.inbox,
    builder: (context, _) {
      final entries = _entries();
      final preferences = widget.inbox.favoritePreferences;
      final list = preferences.layout == 'list';
      final selected = [
        for (final id in _selected)
          if (_byId[id] != null) _byId[id]!,
      ];
      final allPinned =
          selected.isNotEmpty &&
          selected.every((entry) => preferences.pinned.containsKey(entry.id));
      final allSelected =
          entries.isNotEmpty &&
          entries.every((entry) => _selected.contains(entry.id));
      final panel = AppPanel(
        title: tr(context, '收藏'),
        embedded: widget.embedded,
        width: 800,
        height: 600,
        onClose: _opened == null ? null : _requestDetailBack,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal:
                widget.embedded && MediaQuery.sizeOf(context).width < 600
                ? 12
                : 0,
          ),
          child: IndexedStack(
            index: _opened == null ? 0 : 1,
            children: [
              FocusScope(
                canRequestFocus: _opened == null,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1280),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          key: const ValueKey('favorites-search'),
                          controller: _search,
                          onChanged: _searchChanged,
                          decoration: InputDecoration(
                            hintText: tr(context, '搜索收藏'),
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon:
                                ValueListenableBuilder<TextEditingValue>(
                                  valueListenable: _search,
                                  builder: (context, value, _) =>
                                      value.text.isEmpty
                                      ? const SizedBox.shrink()
                                      : IconButton(
                                          tooltip: tr(context, '清空搜索'),
                                          onPressed: () {
                                            _search.clear();
                                            _searchChanged('');
                                          },
                                          icon: const Icon(Icons.close_rounded),
                                        ),
                                ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Text(
                                tr(
                                  context,
                                  _selecting ? '已选 {count} 条' : '共 {count} 项收藏',
                                  {
                                    'count': _selecting
                                        ? _selected.length
                                        : entries.length,
                                  },
                                ),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            if (_selecting) ...[
                              TextButton(
                                key: const ValueKey('favorites-select-all'),
                                onPressed: _busy || entries.isEmpty
                                    ? null
                                    : () => setState(() {
                                        if (allSelected) {
                                          _selected.removeAll(
                                            entries.map((entry) => entry.id),
                                          );
                                        } else {
                                          _selected.addAll(
                                            entries.map((entry) => entry.id),
                                          );
                                        }
                                      }),
                                child: Text(
                                  tr(context, allSelected ? '取消全选' : '全选'),
                                ),
                              ),
                              TextButton.icon(
                                key: const ValueKey('favorites-pin-selected'),
                                onPressed: _busy || selected.isEmpty
                                    ? null
                                    : () => _pin(selected, !allPinned),
                                icon: const Icon(
                                  Icons.push_pin_outlined,
                                  size: 18,
                                ),
                                label: Text(
                                  tr(context, allPinned ? '取消置顶' : '置顶'),
                                ),
                              ),
                              TextButton.icon(
                                key: const ValueKey(
                                  'favorites-export-selected',
                                ),
                                onPressed: _busy || selected.isEmpty
                                    ? null
                                    : () => _perform(
                                        () => _actions.export(selected),
                                        '已导出收藏',
                                      ),
                                icon: const Icon(
                                  Icons.archive_outlined,
                                  size: 18,
                                ),
                                label: Text(tr(context, '导出')),
                              ),
                              TextButton.icon(
                                key: const ValueKey(
                                  'favorites-delete-selected',
                                ),
                                onPressed: _busy || selected.isEmpty
                                    ? null
                                    : () => _delete(selected),
                                style: TextButton.styleFrom(
                                  foregroundColor: Theme.of(
                                    context,
                                  ).colorScheme.error,
                                ),
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  size: 18,
                                ),
                                label: Text(tr(context, '删除收藏')),
                              ),
                            ],
                            TextButton.icon(
                              key: const ValueKey('favorites-select-mode'),
                              onPressed:
                                  _busy || (entries.isEmpty && !_selecting)
                                  ? null
                                  : () => setState(() {
                                      _selecting = !_selecting;
                                      _selected.clear();
                                    }),
                              icon: Icon(
                                _selecting
                                    ? Icons.close_rounded
                                    : Icons.checklist_rounded,
                                size: 18,
                              ),
                              label: Text(
                                tr(context, _selecting ? '取消选择' : '选择收藏'),
                              ),
                            ),
                            FavoriteViewControls(
                              preferences: preferences,
                              showMenus: !_selecting,
                              enabled: !_busy,
                              onChanged: (value) =>
                                  unawaited(_preferences(value)),
                              onLayout: (value) => unawaited(_layout(value)),
                            ),
                          ],
                        ),
                        if (_error != null) AppStatusMessage(_error!),
                        if (_busy) const LinearProgressIndicator(),
                        if (_ordering &&
                            (preferences.sort == 'titleAsc' ||
                                preferences.sort == 'titleDesc'))
                          const LinearProgressIndicator(minHeight: 2),
                        const SizedBox(height: 8),
                        Expanded(
                          child: entries.isEmpty
                              ? AppEmptyState(
                                  icon: Icons.star_border_rounded,
                                  title: tr(
                                    context,
                                    preferences.filter != 'all' ||
                                            preferences.onlyPinned
                                        ? '筛选后暂无收藏'
                                        : _query.isEmpty
                                        ? '暂无收藏'
                                        : '没有找到匹配的收藏',
                                  ),
                                  description: tr(
                                    context,
                                    '在消息菜单中选择收藏，也可以多选后一起收藏。',
                                  ),
                                )
                              : Scrollbar(
                                  controller: _scroll,
                                  child: list
                                      ? ListView.separated(
                                          key: const PageStorageKey(
                                            'favorites-list-view',
                                          ),
                                          controller: _scroll,
                                          padding: const EdgeInsets.only(
                                            bottom: 16,
                                          ),
                                          itemCount: entries.length,
                                          separatorBuilder: (_, _) =>
                                              const SizedBox(height: 8),
                                          itemBuilder: (context, index) =>
                                              _item(
                                                context,
                                                entries[index],
                                                list: true,
                                              ),
                                        )
                                      : FavoriteMasonry(
                                          entries: entries,
                                          controller: _scroll,
                                          layoutToken: (
                                            _query,
                                            preferences.filter,
                                            preferences.onlyPinned,
                                            preferences.sort,
                                            _pinsKey,
                                            preferences.sort.startsWith('title')
                                                ? _titleRanksRevision
                                                : 0,
                                          ),
                                          itemBuilder: (context, entry) =>
                                              _item(
                                                context,
                                                entry,
                                                list: false,
                                              ),
                                        ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_opened != null)
                Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 920),
                    child: FavoriteDetail(
                      key: _detailKey,
                      inbox: widget.inbox,
                      entry: _opened!,
                      embedded: true,
                      onBack: _back,
                      onLocate: widget.onLocate,
                      onDelete: () => _delete([_opened!]),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      return widget.embedded
          ? panel
          : PopScope(
              canPop: _opened == null,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) _requestDetailBack();
              },
              child: panel,
            );
    },
  );
}

class _FavoriteImageRequest {
  _FavoriteImageRequest(this.digest, this.revision);
  final String digest;
  final int revision;
  late final Future<File> future;
  bool failed = false;
}
