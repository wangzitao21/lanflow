part of 'home_page.dart';

extension _MessageCommands on _HomePageState {
  void _selectionChanged() {
    if (mounted) _rebuild(() {});
    _updateReading();
  }

  void _beginSelection([String? id]) {
    if (_selection.busy) return;
    _desktopMenu.close();
    _dismissKeyboard();
    _selection.begin(inbox.conversationId, id);
  }

  Future<void> _selectAllMessages() async {
    if (_selection.busy) return;
    final conversation = inbox.conversationId;
    _selection.setBusy(true);
    try {
      final ids = await inbox.store.conversationIds(conversation);
      if (mounted && _selection.conversation == conversation) {
        _selection.setBusy(false);
        _selection.selectAll(ids);
      }
    } on Object catch (error) {
      _toast(userError(error, fallback: '聊天记录加载失败，请重试'));
    } finally {
      if (mounted) _selection.setBusy(false);
    }
  }

  Future<void> _favoriteMessages(List<String> ids, bool value) async {
    if (ids.isEmpty || _selection.busy) return;
    if (!value && inbox.linkFavoriteDeletion) {
      final confirmed = await _dialog<bool>(
        context: context,
        builder: (_) => AppConfirmDialog(
          title: tr(context, '删除收藏及原消息？'),
          confirmLabel: tr(context, '删除'),
          message: tr(context, '已开启联动删除，同时删除仍存在的原消息；可分别在回收站恢复收藏和原消息。'),
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    _selection.setBusy(true);
    try {
      await inbox.setFavorites(ids, value);
      _toast(value ? '已加入收藏' : '已取消收藏');
    } on Object catch (error) {
      _toast(userError(error, fallback: '收藏操作失败，请重试'));
    } finally {
      if (mounted) _selection.setBusy(false);
    }
  }

  Future<void> _deleteSelection() async {
    if (_selection.busy || _selection.ids.isEmpty) return;
    List<InboxEntry> entries;
    _selection.setBusy(true);
    try {
      entries = await inbox.store.loadEntries(_selection.ids);
    } on Object catch (error) {
      _toast(userError(error, fallback: '聊天记录加载失败，请重试'));
      return;
    } finally {
      if (mounted) _selection.setBusy(false);
    }
    if (!mounted) return;
    final confirmed = await _dialog<bool>(
      context: context,
      builder: (_) => AppConfirmDialog(
        title: tr(context, '删除 {count} 条消息？', {'count': entries.length}),
        confirmLabel: tr(context, '删除'),
        message: tr(
          context,
          inbox.linkFavoriteDeletion
              ? '所选消息会移至回收站，对应收藏也会删除。已绑定设备将同步这些更改。'
              : '所选消息会移至回收站，并同步删除已绑定设备上的副本。收藏不受影响。',
        ),
      ),
    );
    if (!mounted || confirmed != true) return;
    _selection.setBusy(true);
    var deleted = false;
    try {
      await inbox.deleteItems(entries.map((e) => e.item.id));
      deleted = true;
      if (mounted) {
        showAppMessage(
          context,
          tr(context, '已删除 {count} 条消息', {'count': entries.length}),
          duration: const Duration(seconds: 1),
          action: SnackBarAction(
            label: tr(context, inbox.linkFavoriteDeletion ? '恢复消息' : '撤销'),
            onPressed: () async {
              try {
                for (final entry in entries) {
                  await inbox.restoreItem(entry.item);
                }
              } on Object catch (error) {
                _toast(userError(error, fallback: '恢复失败，请重试'));
              }
            },
          ),
        );
      }
    } on Object catch (error) {
      _toast(userError(error, fallback: '删除失败，请重试'));
    } finally {
      if (mounted) {
        _selection.setBusy(false);
        if (deleted) _selection.clear();
      }
    }
  }

  Future<void> _exportSelection() async {
    if (_selection.busy || _selection.ids.isEmpty) return;
    String? destination;
    if (!Platform.isAndroid) {
      destination = (await getSaveLocation(
        suggestedName: 'LanFlow-messages.zip',
      ))?.path;
      if (destination == null) return;
    }
    if (!mounted) return;
    _selection.setBusy(true);
    Directory? temporary;
    try {
      final entries = await inbox.store.loadEntries(_selection.ids);
      entries.sort((a, b) => a.item.createdAt.compareTo(b.item.createdAt));
      final records = <Map<String, dynamic>>[];
      for (final entry in entries) {
        records.add({
          ...entry.item.toJson(),
          if (entry.item.isFile)
            'sourcePath': (await inbox.store.fileForExport(entry.item)).path,
        });
      }
      final cache = StorageLayout.previews(inbox.store.directory);
      await cache.create(recursive: true);
      temporary = await cache.createTemp('export-');
      final archive = await exportMessages(records, temporary);
      final saved = Platform.isAndroid
          ? await PlatformBridge.exportFile(
              archive.path,
              'LanFlow-messages.zip',
            )
          : await archive.copy(destination!).then((_) => true);
      if (saved) _toast('已导出所选消息和附件');
    } on Object catch (error) {
      _toast(userError(error, fallback: '导出失败，请重试'));
    } finally {
      if (temporary != null && await temporary.exists()) {
        await temporary.delete(recursive: true);
      }
      if (mounted) _selection.setBusy(false);
    }
  }

  Future<void> _locateFavorite(InboxEntry entry) async {
    try {
      await inbox.store.loadContext(entry.item.id);
    } on Object catch (error) {
      _toast(userError(error, fallback: '聊天记录加载失败，请重试'));
      return;
    }
    if (!mounted) return;
    _openConversation(entry.item.conversationId);
    _rebuild(() {
      _locatedFromFavorites = true;
      _locatedMessage = entry.item.id;
      _locatedQuery = '';
    });
  }

  Future<void> _favorites() async {
    if (AppLayout.desktop(context)) {
      _selectDesktopSection(MobileSection.favorites);
    } else if (_touchNavigation) {
      _selectMobileSection(MobileSection.favorites);
    } else {
      final entry = await _dialog<InboxEntry>(
        context: context,
        builder: (context) => FavoritesPanel(
          inbox: inbox,
          onLocate: (entry) => Navigator.pop(context, entry),
        ),
      );
      if (entry != null && mounted) _locateFavorite(entry);
    }
  }
}
