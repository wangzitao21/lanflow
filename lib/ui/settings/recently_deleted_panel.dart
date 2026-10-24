import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';
import 'package:lanflow/ui/shared/app_feedback.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/app_dialogs.dart';

class RecentlyDeletedPanel extends StatefulWidget {
  const RecentlyDeletedPanel({
    super.key,
    required this.inbox,
    this.embedded = false,
    this.active = true,
  });
  final InboxController inbox;
  final bool embedded;
  final bool active;

  @override
  State<RecentlyDeletedPanel> createState() => _RecentlyDeletedPanelState();
}

class _RecentlyDeletedPanelState extends State<RecentlyDeletedPanel> {
  List<DeletedItem>? _items;
  bool _loading = true;
  final _restoring = <String>{};
  int _generation = 0;
  String? _error, _notice;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _searchTimer;
  Map<String, dynamic>? _cursor;
  int _total = 0;
  int _unfilteredTotal = 0;
  int? _unfilteredRevision;
  bool _more = false;
  int _loadedPages = 1;
  int? _loadedRevision, _requestedRevision;
  bool _refreshPending = false;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    widget.inbox.addListener(_changed);
    _loading = widget.active;
    if (widget.active) _load();
  }

  void _changed() {
    if (!widget.active || _clearing || _restoring.isNotEmpty) return;
    final revision = widget.inbox.store.revision;
    if (revision == (_loading ? _requestedRevision : _loadedRevision)) return;
    if (_loading) {
      _refreshPending = true;
    } else {
      unawaited(_load());
    }
  }

  @override
  void didUpdateWidget(covariant RecentlyDeletedPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inbox != widget.inbox) {
      oldWidget.inbox.removeListener(_changed);
      widget.inbox.addListener(_changed);
      _items = null;
      _cursor = null;
      _loadedPages = 1;
      _loadedRevision = null;
      _unfilteredRevision = null;
      _unfilteredTotal = 0;
    }
    if (!widget.active) {
      // A retained desktop pane must not keep reading storage off screen.
      _generation++;
      _loading = false;
      _refreshPending = false;
      _searchTimer?.cancel();
    } else if (!oldWidget.active || oldWidget.inbox != widget.inbox) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _search.dispose();
    _scroll.dispose();
    widget.inbox.removeListener(_changed);
    super.dispose();
  }

  Future<void> _load({bool append = false, bool reset = false}) async {
    if (!widget.active) return;
    if (append && (_loading || !_more)) return;
    final generation = ++_generation;
    final requestedRevision = widget.inbox.store.revision;
    _requestedRevision = requestedRevision;
    _refreshPending = false;
    if (reset) {
      _loadedPages = 1;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
    final pageCount = append ? 1 : _loadedPages;
    final query = _search.text;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var unfilteredTotal = _unfilteredTotal;
      if (query.trim().isNotEmpty && _unfilteredRevision != requestedRevision) {
        final all = await widget.inbox.store.deletedPage();
        if (!mounted || generation != _generation || !widget.active) return;
        unfilteredTotal = all['total'] as int;
      }
      final items = <DeletedItem>[];
      Map<String, dynamic>? cursor = append ? _cursor : null;
      var total = 0, pages = 0;
      var more = false;
      for (; pages < pageCount; pages++) {
        final page = await widget.inbox.store.deletedPage(
          after: cursor,
          query: query,
        );
        if (!mounted || generation != _generation || !widget.active) return;
        items.addAll(
          (page['items'] as List).map(
            (v) => DeletedItem.fromJson(Map<String, dynamic>.from(v as Map)),
          ),
        );
        cursor = page['cursor'] == null
            ? null
            : Map<String, dynamic>.from(page['cursor'] as Map);
        total = page['total'] as int;
        more = page['more'] == true;
        if (!more) {
          pages++;
          break;
        }
      }
      if (mounted && generation == _generation) {
        setState(() {
          _items = append ? [...?_items, ...items] : items;
          _cursor = cursor;
          _total = total;
          _unfilteredTotal = query.trim().isEmpty ? total : unfilteredTotal;
          _unfilteredRevision = requestedRevision;
          _more = more;
          _loadedPages = append ? _loadedPages + pages : pages;
          _loadedRevision = requestedRevision;
        });
      }
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = userError(error, fallback: '无法加载回收站，请重试'));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
        if (_refreshPending && widget.active) unawaited(_load());
      }
    }
  }

  Future<void> _restore(DeletedItem item) async {
    if (_clearing) return;
    if (!_restoring.add(item.id)) return;
    setState(() {
      _error = null;
      _notice = null;
    });
    try {
      await widget.inbox.restoreDeleted(item);
      if (mounted) {
        setState(() => _notice = item.isFavorite ? '已恢复到收藏' : '已恢复到原会话');
        await _load();
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = userError(error, fallback: '恢复失败，请重试'));
      }
    } finally {
      _restoring.remove(item.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _clearTrash() async {
    final cleanup = widget.inbox.cleanupStorage;
    if (_clearing || _loading || _restoring.isNotEmpty || cleanup == null) {
      return;
    }
    setState(() {
      _clearing = true;
      _error = null;
      _notice = null;
    });
    DialogRoute<void>? progress;
    NavigatorState? navigator;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AppConfirmDialog(
          title: tr(context, '清空回收站？'),
          confirmLabel: tr(context, '永久清空'),
          message: tr(
            context,
            '将永久移除本机回收站中的恢复记录。其他设备的回收站不受影响。此操作无法撤销；仅释放未被消息、收藏、草稿或传输任务使用的附件。',
          ),
        ),
      );
      if (!mounted || confirmed != true) return;
      _searchTimer?.cancel();
      _generation++;
      _refreshPending = false;
      navigator = Navigator.of(context, rootNavigator: true);
      progress = DialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => PopScope(
          canPop: false,
          child: AlertDialog(
            key: const ValueKey('empty-trash-progress'),
            content: Row(
              children: [
                const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 16),
                Expanded(child: Text(tr(context, '正在清空回收站…'))),
              ],
            ),
          ),
        ),
      );
      unawaited(navigator.push(progress));
      // Runtime suspends edits/sync and reopens storage. The local route also
      // protects embedded hosts that provide only this callback.
      await cleanup(true);
      if (mounted) {
        _search.clear();
        await _load(reset: true);
        if (mounted) setState(() => _notice = '已清空回收站');
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = userError(error, fallback: '清理未完成，请重试'));
      }
    } finally {
      if (navigator != null &&
          navigator.mounted &&
          progress != null &&
          progress.isActive) {
        navigator.removeRoute(progress);
      }
      if (mounted) {
        setState(() => _clearing = false);
        _changed();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(tr(context, '恢复后会回到原位置，并同步到已绑定设备。')),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('trash-search'),
          controller: _search,
          enabled: !_clearing,
          decoration: InputDecoration(
            hintText: tr(context, '搜索已删除的文字或文件名'),
            prefixIcon: const Icon(Icons.search),
          ),
          onChanged: (_) {
            _searchTimer?.cancel();
            _searchTimer = Timer(
              const Duration(milliseconds: 200),
              () => _load(reset: true),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(tr(context, '共 {count} 条', {'count': _total})),
        ),
        if (_notice != null) AppStatusMessage(_notice!, error: false),
        if (_error != null) AppStatusMessage(_error!),
        if (_loading && _items != null) const LinearProgressIndicator(),
        Expanded(
          child: _items == null && _loading
              ? const Center(child: CircularProgressIndicator())
              : _items?.isEmpty != false
              ? AppEmptyState(
                  title: _error == null ? '暂无已删除内容' : '点击刷新重新加载',
                  icon: Icons.restore_from_trash_outlined,
                )
              : ListView.separated(
                  key: const ValueKey('trash-list'),
                  controller: _scroll,
                  itemCount: _items!.length + (_more ? 1 : 0),
                  separatorBuilder: (_, _) => const Divider(height: 20),
                  itemBuilder: (context, index) {
                    if (index == _items!.length) {
                      return TextButton(
                        key: const ValueKey('trash-load-more'),
                        onPressed: _loading || _clearing
                            ? null
                            : () => _load(append: true),
                        child: Text(tr(context, _loading ? '加载中…' : '加载更多')),
                      );
                    }
                    final item = _items![index];
                    final busy = _restoring.contains(item.id);
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        item.isFavorite
                            ? Icons.star_border_rounded
                            : Icons.chat_bubble_outline_rounded,
                      ),
                      title: Text(
                        item.item.isFile ? item.item.name : item.item.text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        item.available
                            ? '${tr(context, item.isFavorite ? '收藏' : '会话')} · ${item.deletedAt.toLocal().toString().substring(0, 16)} · ${item.item.originName}'
                            : tr(context, '本机附件不可用，请在保留附件的设备上恢复'),
                      ),
                      trailing: TextButton(
                        key: ValueKey('restore-${item.id}'),
                        onPressed: busy || _clearing || !item.available
                            ? null
                            : () => _restore(item),
                        child: Text(tr(context, busy ? '恢复中' : '恢复')),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
    final actions = [
      TextButton.icon(
        key: const ValueKey('empty-local-trash'),
        onPressed:
            _clearing ||
                _loading ||
                _restoring.isNotEmpty ||
                widget.inbox.cleanupStorage == null ||
                _unfilteredTotal == 0
            ? null
            : _clearTrash,
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.error,
        ),
        icon: const Icon(Icons.delete_forever_outlined),
        label: Text(tr(context, '清空回收站')),
      ),
      TextButton(
        onPressed: _loading || _clearing ? null : _load,
        child: Text(tr(context, '刷新')),
      ),
    ];
    return PopScope(
      canPop: !_clearing,
      child: AppPanel(
        embedded: widget.embedded,
        title: '回收站',
        width: 560,
        height: 500,
        canClose: !_clearing,
        actions: actions,
        child: content,
      ),
    );
  }
}
