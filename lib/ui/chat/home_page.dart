import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:lanflow/core/files/message_export.dart';
import 'package:lanflow/core/storage/storage_layout.dart';

import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/platform/platform_bridge.dart';
import 'package:lanflow/platform/app_file_picker.dart';
import 'package:lanflow/ui/chat/chat_composer.dart';
import 'package:lanflow/ui/chat/chat_body_layout.dart';
import 'package:lanflow/ui/chat/chat_history_view.dart';
import 'package:lanflow/ui/chat/message_presentation.dart';
import 'package:lanflow/ui/chat/chat_header.dart';
import 'package:lanflow/ui/chat/chat_sidebar.dart';
import 'package:lanflow/ui/chat/desktop_navigation.dart';
import 'package:lanflow/ui/chat/conversation_list.dart';
import 'package:lanflow/ui/chat/conversation_dialogs.dart';
import 'package:lanflow/ui/shared/app_feedback.dart';
import 'package:lanflow/ui/chat/desktop_menu.dart';
import 'package:lanflow/ui/chat/image_viewer.dart';
import 'package:lanflow/ui/chat/message_actions.dart';
import 'package:lanflow/ui/chat/message_tile.dart';
import 'package:lanflow/ui/chat/message_selection.dart';
import 'package:lanflow/ui/chat/favorites_panel.dart';
import 'package:lanflow/ui/chat/message_search_panel.dart';
import 'package:lanflow/ui/chat/message_context.dart';
import 'package:lanflow/ui/chat/mobile_home.dart';
import 'package:lanflow/ui/chat/sync_feedback.dart';
import 'package:lanflow/ui/devices/device_dialogs.dart';
import 'package:lanflow/ui/settings/settings_panel.dart';
import 'package:lanflow/ui/settings/transfer_dialog.dart';
import 'package:lanflow/ui/settings/recently_deleted_panel.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/motion.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/chat/sync_details.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';
import 'package:lanflow/ui/shared/app_dialogs.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/share_import_notice.dart';
import 'share_receiver_page.dart';
import 'attachment_selection_page.dart';

part 'message_commands.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    required this.inbox,
    this.interactionsBlocked = false,
    this.initialSection = MobileSection.conversations,
  });
  final LanController controller;
  final InboxController inbox;
  final bool interactionsBlocked;
  final MobileSection initialSection;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  ChatPalette get palette => ChatPalette.of(context);
  Color get muted => palette.muted;
  LanController get lan => widget.controller;
  InboxController get inbox => widget.inbox;
  final _composer = TextEditingController();
  final _hasText = ValueNotifier(false);
  final _selection = MessageSelection();
  MessageSearchSession? _lastSearch;
  MessageSearchSession? _chatSearch;
  late final _globalSearch = MessageSearchSession(
    conversationId: inbox.conversationId,
    all: true,
  );
  String? _locatedMessage;
  bool _locatedFromFavorites = false;
  bool _locatedFromQuote = false;
  String _locatedQuery = '';
  bool _searchOpen = false;
  bool _focusSearch = true;
  bool _foreground = true;
  final _focus = FocusNode();
  final _pageFocus = FocusNode(debugLabel: 'Chat window');
  final _scroll = ScrollController();
  final _atLatest = ValueNotifier(true);
  final _historyViewport = GlobalKey();
  final _rowKeys = <String, GlobalKey>{};
  final _readingOffsets = <String, double>{};
  late String _visibleConversation;
  int _seenRevision = -1;
  int _scrollRequest = 0;
  bool _pruningRows = false;
  final _desktopMenu = DesktopMenuController();
  final _editorMenuKey = GlobalKey();
  bool _mobileChat = false;
  MobileSection _mobileSection = MobileSection.conversations;
  VoidCallback? _favoriteBack;
  final _openedDesktopSections = <MobileSection>{MobileSection.conversations};
  final _conversationName = TextEditingController();
  final _conversationNameFocus = FocusNode(debugLabel: 'Conversation name');
  String? _editingConversation;
  final _pendingConversationNames = <String, String>{};
  final _conversationNameWrites = <String, Future<void>>{};
  late final Future<void> Function() _commitUiEdits = _commitConversationNames;
  int _readingTransitions = 0;
  bool _creatingConversation = false;
  String? _draftConversation;
  bool _saving = false;
  bool _addingAttachments = false;
  bool _choosingAttachments = false;
  bool _attachmentPanel = false;
  double _keyboardHeight = 280;
  bool _restoreKeyboard = false;
  double? _heldComposerInset;
  Size? _heldComposerSize;
  Timer? _releaseComposerTimer;
  bool _dropping = false;
  bool _loadedDraft = false;
  bool _menuOpen = false;
  bool _openingFile = false;
  PageRoute<void>? _viewerRoute;
  String? _selectedMessage;
  String? _selectedText;
  String _draftText = '';
  Widget? _historyWidget;
  Object? _historyKey;
  late final DeviceDialogs _deviceDialogs;
  late final ConversationDialogs _conversationDialogs;
  final _dialogFocusNodes = <FocusNode>[];
  late final _sharePresenter = _presentShare;

  @override
  void initState() {
    super.initState();
    _mobileSection = widget.initialSection;
    _openedDesktopSections.add(widget.initialSection);
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addEarlyKeyEventHandler(_handleKey);
    _deviceDialogs = DeviceDialogs(
      context: context,
      inbox: inbox,
      showDialog: _dialog,
      onError: _toast,
    );
    _conversationDialogs = ConversationDialogs(
      inbox: inbox,
      showDialog: _dialog,
      onCreated: _openConversation,
    );
    lan.onPrompt = _deviceDialogs.confirmPairing;
    lan.addListener(_update);
    inbox.addListener(_update);
    PlatformBridge.onNetworkChanged = (available) {
      if (available) inbox.setNetworkAvailable(false);
      inbox.setNetworkAvailable(available);
      if (available) unawaited(lan.refresh().catchError((Object _) {}));
    };
    PlatformBridge.onNetworkStateChanged = inbox.setNetworkState;
    _composer.addListener(_draftChanged);
    _conversationNameFocus.addListener(_conversationNameFocusChanged);
    inbox.onCommitPendingEdits = _commitUiEdits;
    _selection.addListener(_selectionChanged);
    _scroll.addListener(_scrolled);
    _visibleConversation = inbox.conversationId;
    _loadDraft();
    _scrollToLatest();
    PlatformBridge.presentShare = _sharePresenter;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(PlatformBridge.drainShares()),
    );
  }

  Future<ShareDisposition> _presentShare(
    Map<String, dynamic> payload,
    Future<void> Function(Map<String, dynamic>) send,
  ) async {
    if (!mounted) throw StateError('分享界面尚未就绪');
    _dismissKeyboard();
    var sent = false;
    final target = await Navigator.of(context).push<ShareSelectionResult>(
      MaterialPageRoute(
        builder: (_) => ShareReceiverPage(
          inbox: inbox,
          payload: payload,
          onSend: (value) async {
            await send(value);
            sent = true;
          },
        ),
      ),
    );
    if (mounted && target?.conversation != null) {
      _openConversation(target!.conversation!);
    }
    return target?.deferred == true
        ? ShareDisposition.deferred
        : sent
        ? ShareDisposition.sent
        : ShareDisposition.cancelled;
  }

  void _loadDraft() {
    if (inbox.ready &&
        (!_loadedDraft || _draftConversation != inbox.conversationId)) {
      _loadedDraft = true;
      _draftConversation = inbox.conversationId;
      _draftText = inbox.store.draft;
      _composer.text = inbox.store.draft;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A narrower window changes the layout, not the conversation being read.
    if (AppLayout.split(context)) _mobileChat = true;
  }

  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.interactionsBlocked && !oldWidget.interactionsBlocked) {
      _desktopMenu.close();
      _dismissKeyboard();
      inbox.setReadingConversation(null);
    }
  }

  void _update() {
    if (!mounted) return;
    _loadDraft();
    if (_visibleConversation != inbox.conversationId) {
      _selection.clear();
      _rememberReadingOffset();
      _visibleConversation = inbox.conversationId;
      if (_locatedMessage == null) {
        _scrollToOffset(_readingOffsets[_visibleConversation] ?? 0);
      }
    } else if (_seenRevision != inbox.store.revision &&
        _locatedMessage == null) {
      if (_atLatest.value) {
        _scrollToLatest();
      } else {
        _preserveReadingAnchor();
      }
    }
    _seenRevision = inbox.store.revision;
    if (_selection.active) {
      _selection.retain(
        inbox.store.pagedHistory
            ? _selection.ids
                  .where((id) => !inbox.store.deleted.contains(id))
                  .toSet()
            : inbox.itemsIn(inbox.conversationId).map((e) => e.item.id).toSet(),
      );
    }
    setState(() {});
  }

  void _rememberReadingOffset() {
    if (_scroll.hasClients && _locatedMessage == null) {
      _readingOffsets[_visibleConversation] = _scroll.offset;
    }
  }

  void _preserveReadingAnchor() {
    if (!_scroll.hasClients) return;
    final viewport = _historyViewport.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return;
    final bounds = viewport.localToGlobal(Offset.zero) & viewport.size;
    (GlobalKey, double)? anchor;
    for (final key in _rowKeys.values) {
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      if (top + box.size.height > bounds.top &&
          top < bounds.bottom &&
          (anchor == null || top < anchor.$2)) {
        anchor = (key, top);
      }
    }
    final previousExtent = _scroll.position.maxScrollExtent;
    final previousOffset = _scroll.offset;
    final request = ++_scrollRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || request != _scrollRequest) return;
      final box = anchor?.$1.currentContext?.findRenderObject();
      final delta = box is RenderBox && box.hasSize
          ? anchor!.$2 - box.localToGlobal(Offset.zero).dy
          : _scroll.position.maxScrollExtent - previousExtent;
      _scroll.jumpTo(
        (previousOffset + delta).clamp(0.0, _scroll.position.maxScrollExtent),
      );
    });
  }

  void _scrolled() {
    if (!_scroll.hasClients) return;
    if (_locatedMessage == null &&
        _scroll.position.extentAfter < 600 &&
        inbox.store.hasOlderHistory(inbox.conversationId) &&
        !inbox.store.loadingHistory(inbox.conversationId)) {
      unawaited(inbox.loadHistory(inbox.conversationId, older: true));
    }
    _atLatest.value = _scroll.position.axisDirection == AxisDirection.up
        ? _scroll.offset < 100
        : _scroll.position.maxScrollExtent - _scroll.offset < 100;
    _rememberReadingOffset();
    if (!_atLatest.value) inbox.setReadingConversation(null);
    if (!_pruningRows) {
      _pruningRows = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _pruningRows = false;
        if (mounted) {
          // Keep only mounted rows as anchors, even after a long scrolling session.
          _rowKeys.removeWhere((_, key) => key.currentContext == null);
          _updateReading();
        }
      });
    }
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (widget.interactionsBlocked) return KeyEventResult.handled;
    if (!mounted || Theme.of(context).platform != TargetPlatform.windows) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      // A single press closes just the top layer; auto-repeat must not also
      // dismiss the underlying window. This works even after focus is cleared.
      if (event is! KeyDownEvent) return KeyEventResult.handled;
      if (_desktopMenu.isOpen) {
        _desktopMenu.close();
      } else if (_editorMenuKey.currentContext != null) {
        ContextMenuController.removeAny();
      } else {
        final navigator = Navigator.of(context, rootNavigator: true);
        if (navigator.canPop()) {
          unawaited(navigator.maybePop());
        } else if (_mobileSection == MobileSection.favorites &&
            _favoriteBack != null) {
          _favoriteBack!();
        } else if (_editingConversation != null) {
          unawaited(_finishRename(cancel: true));
        } else if (_selection.active) {
          _selection.clear();
        } else if (_searchOpen) {
          _closeSearch();
        } else if (AppLayout.desktop(context) &&
            _mobileSection != MobileSection.conversations) {
          _selectDesktopSection(MobileSection.conversations);
        } else if (_globalSearch.focus.hasFocus ||
            _globalSearch.query.isNotEmpty) {
          _globalSearch.input.clear();
          _globalSearch.focus.unfocus();
        } else if (_locatedMessage != null) {
          _leaveLocation();
        } else {
          _dismissKeyboard();
          unawaited(
            PlatformBridge.hideToTray().catchError(
              (Object error) =>
                  _toast(userError(error, fallback: '无法收起窗口，请重试')),
            ),
          );
        }
      }
      return KeyEventResult.handled;
    }
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    final editingText =
        focusedContext?.widget is EditableText ||
        focusedContext?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (_selection.active &&
        !editingText &&
        !_focus.hasFocus &&
        !_conversationNameFocus.hasFocus &&
        event is KeyDownEvent &&
        (ModalRoute.of(context)?.isCurrent ?? false)) {
      if (event.logicalKey == LogicalKeyboardKey.keyA &&
          HardwareKeyboard.instance.isControlPressed) {
        _selectAllMessages();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.delete) {
        unawaited(_deleteSelection());
        return KeyEventResult.handled;
      }
    }
    if (event is KeyDownEvent &&
        HardwareKeyboard.instance.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.keyF &&
        (ModalRoute.of(context)?.isCurrent ?? false)) {
      _desktopMenu.close();
      _openSearch(all: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _openSearch({bool all = true, bool resume = false}) =>
      _transitionReading(() {
        if (AppLayout.desktop(context) &&
            _mobileSection != MobileSection.conversations) {
          _selectDesktopSection(MobileSection.conversations);
        }
        _selection.clear();
        _desktopMenu.close();
        _rememberReadingOffset();
        if (all || (resume && identical(_lastSearch, _globalSearch))) {
          setState(() {
            _searchOpen = false;
            if (!AppLayout.split(context)) _mobileChat = false;
            _mobileSection = MobileSection.conversations;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !resume) _globalSearch.focus.requestFocus();
          });
          return;
        }
        if (_searchOpen) {
          _chatSearch!.focus.requestFocus();
          return;
        }
        if (!resume || _chatSearch == null) {
          _chatSearch?.dispose();
          _chatSearch = MessageSearchSession(
            conversationId: inbox.conversationId,
          );
        }
        _lastSearch = _chatSearch;
        setState(() {
          _searchOpen = true;
          _focusSearch = !resume;
          _mobileChat = true;
        });
        _updateReading();
      });

  void _closeSearch() {
    _chatSearch?.focus.unfocus();
    setState(() => _searchOpen = false);
    if (_locatedMessage == null) {
      _scrollToOffset(_readingOffsets[inbox.conversationId] ?? 0);
    }
    _updateReading();
  }

  Future<void> _selectSearchResult(
    MessageSearchSelection result,
    MessageSearchSession session,
  ) async {
    _locatedFromFavorites = false;
    _locatedFromQuote = false;
    _lastSearch = session;
    _dismissKeyboard();
    if (result.entry == null) {
      if (identical(session, _globalSearch)) _globalSearch.input.clear();
      _openConversation(result.conversationId);
      return;
    }
    InboxEntry? entry;
    try {
      entry = await inbox.store.loadEntry(result.entry!.item.id);
      if (entry != null) await inbox.store.loadContext(entry.item.id);
    } on Object catch (error) {
      _toast(userError(error, fallback: '搜索失败，请重试'));
      return;
    }
    if (!mounted) return;
    if (entry == null) {
      _toast('这条消息已删除，请重新搜索');
      return;
    }
    _rememberReadingOffset();
    _locatedMessage = entry.item.id;
    _locatedQuery = result.query.trim();
    _scrollRequest++;
    inbox.selectConversation(entry.item.conversationId, markRead: false);
    setState(() {
      _searchOpen = false;
      _mobileChat = true;
      _mobileSection = MobileSection.conversations;
    });
    _updateReading();
  }

  void _leaveLocation({bool latest = false}) {
    setState(() {
      _locatedFromQuote = false;
      _locatedFromFavorites = false;
      _locatedMessage = null;
      _locatedQuery = '';
    });
    _scrollToOffset(latest ? 0 : (_readingOffsets[inbox.conversationId] ?? 0));
  }

  void _scrollToLatest({bool animate = false}) =>
      _scrollToOffset(0, animate: animate);

  void _scrollToOffset(double offset, {bool animate = false}) {
    final request = ++_scrollRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients && request == _scrollRequest) {
        final target = offset.clamp(0.0, _scroll.position.maxScrollExtent);
        final duration = animate ? AppMotion.duration(context) : Duration.zero;
        if (duration == Duration.zero ||
            (_scroll.offset - target).abs() >
                _scroll.position.viewportDimension * 3) {
          _scroll.jumpTo(target);
        } else {
          unawaited(
            _scroll.animateTo(
              target,
              duration: duration,
              curve: AppMotion.curve,
            ),
          );
        }
        _scrolled();
      }
    });
  }

  void _draftChanged() {
    final text = _composer.text;
    _hasText.value = text.trim().isNotEmpty;
    // Caret movement and focus changes are not edits. Typing updates only the
    // editor/send button, never the chat history or avatar/image providers.
    if (_loadedDraft && text != _draftText) {
      _draftText = text;
      inbox.setDraft(text);
    }
  }

  @override
  void didChangeMetrics() {
    _desktopMenu.close();
    final view = View.of(context);
    final inset = view.viewInsets.bottom / view.devicePixelRatio;
    if (_heldComposerInset != null &&
        view.physicalSize.width / view.devicePixelRatio !=
            _heldComposerSize?.width) {
      _clearComposerHold();
    }
    if (_heldComposerInset != null &&
        !_openingFile &&
        !_choosingAttachments &&
        _composerBottomRestored) {
      _clearComposerHold();
    }
    if (inset > 150 && _heldComposerInset == null) _keyboardHeight = inset;
    if (_heldComposerInset == null && _focus.hasFocus && _atLatest.value) {
      _scrollToLatest();
    }
  }

  void _holdComposerPosition() {
    if (AppLayout.desktop(context)) return;
    final view = View.of(context);
    final inset = view.viewInsets.bottom / view.devicePixelRatio;
    if (!_focus.hasFocus || inset <= 0) return;
    _releaseComposerTimer?.cancel();
    setState(() {
      _heldComposerInset = inset;
      _heldComposerSize = MediaQuery.sizeOf(context);
    });
  }

  void _clearComposerHold() {
    _releaseComposerTimer?.cancel();
    _releaseComposerTimer = null;
    if (!mounted || _heldComposerInset == null) return;
    setState(() {
      _heldComposerInset = null;
      _heldComposerSize = null;
    });
  }

  void _releaseComposerPosition() {
    if (!mounted || _heldComposerInset == null) return;
    if (_composerBottomRestored || !_foreground) {
      _clearComposerHold();
    } else {
      // Keep the chat anchored through the IME's restoration animation.
      // A dismissed keyboard must not leave a permanent blank area.
      _releaseComposerTimer?.cancel();
      _releaseComposerTimer = Timer(
        const Duration(milliseconds: 800),
        _clearComposerHold,
      );
    }
  }

  bool get _composerBottomRestored {
    final view = View.of(context);
    final current =
        (view.physicalSize.height - view.viewInsets.bottom) /
        view.devicePixelRatio;
    return (current - (_heldComposerSize!.height - _heldComposerInset!)).abs() <
        1;
  }

  MediaQueryData _composerViewport() {
    final data = MediaQuery.of(context);
    final held = _heldComposerInset;
    if (held == null) return data;
    // Some Android hosts resize the Flutter view; others update only IME
    // insets. Preserve the usable bottom coordinate in either representation.
    final inset = (data.size.height - (_heldComposerSize!.height - held)).clamp(
      0.0,
      data.size.height,
    );
    return data.copyWith(
      viewInsets: data.viewInsets.copyWith(bottom: inset),
      padding: data.padding.copyWith(
        bottom: (data.viewPadding.bottom - inset).clamp(
          0.0,
          data.viewPadding.bottom,
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive && _foreground) {
      _restoreKeyboard =
          _focus.hasFocus &&
          MediaQuery.viewInsetsOf(context).bottom > 0 &&
          !_attachmentPanel;
    }
    _foreground = state == AppLifecycleState.resumed;
    inbox.setForeground(_foreground);
    unawaited(PlatformBridge.setForeground(_foreground));
    _updateReading();
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _desktopMenu.close();
      unawaited(
        _flushEditedState().catchError((Object error) {
          inbox.reportError('草稿保存失败：$error');
        }),
      );
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(lan.refresh().catchError((Object _) {}));
      inbox.requestSync();
      unawaited(PlatformBridge.drainShares());
      if (_restoreKeyboard && !_choosingAttachments && !_openingFile) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _mobileChat &&
              !_attachmentPanel &&
              (ModalRoute.of(context)?.isCurrent ?? false)) {
            _focus.requestFocus();
            unawaited(
              SystemChannels.textInput.invokeMethod<void>('TextInput.show'),
            );
          }
        });
      }
    }
    if (state == AppLifecycleState.detached) unawaited(_close());
  }

  Future<void> _close() async {
    await inbox.close();
    await lan.close();
  }

  Future<void> _flushEditedState() async {
    await inbox.commitPendingEdits();
    await inbox.flushLocalWrites();
  }

  @override
  void dispose() {
    _releaseComposerTimer?.cancel();
    if (identical(PlatformBridge.presentShare, _sharePresenter)) {
      PlatformBridge.presentShare = null;
    }
    PlatformBridge.onNetworkChanged = null;
    PlatformBridge.onNetworkStateChanged = null;
    if (identical(inbox.onCommitPendingEdits, _commitUiEdits)) {
      inbox.onCommitPendingEdits = null;
    }
    _conversationNameFocus.removeListener(_conversationNameFocusChanged);
    _conversationNameFocus.dispose();
    _conversationName.dispose();
    _selection.removeListener(_selectionChanged);
    _selection.dispose();
    inbox.setReadingConversation(null);
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKey);
    _desktopMenu.dispose();
    lan.removeListener(_update);
    inbox.removeListener(_update);
    lan.onPrompt = null;
    _composer.dispose();
    _hasText.dispose();
    _focus.dispose();
    _pageFocus.dispose();
    _atLatest.dispose();
    _scroll.dispose();
    _globalSearch.dispose();
    _chatSearch?.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    showAppMessage(context, message);
  }

  void _dismissKeyboard() {
    _restoreKeyboard = false;
    if (_attachmentPanel) setState(() => _attachmentPanel = false);
    _focus.unfocus(disposition: UnfocusDisposition.scope);
    FocusManager.instance.primaryFocus?.unfocus();
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      _pageFocus.requestFocus();
    }
    if (Platform.isAndroid) {
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    }
  }

  Future<T?> _dialog<T>({
    required BuildContext context,
    required WidgetBuilder builder,
  }) async {
    if (widget.interactionsBlocked) return null;
    _desktopMenu.close();
    _dismissKeyboard();
    final dialogFocus = FocusNode(debugLabel: 'Dialog actions');
    _dialogFocusNodes.add(dialogFocus);
    inbox.setReadingConversation(null);
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<T>(
      context: context,
      requestFocus: true,
      animationStyle: AnimationStyle(
        duration: AppMotion.duration(context, 160),
        reverseDuration: AppMotion.duration(context, 120),
        curve: AppMotion.curve,
      ),
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      builder: (context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.maybePop(context),
        },
        child: Focus(
          focusNode: dialogFocus,
          autofocus: _focusSearch,
          child: builder(context),
        ),
      ),
    );
    final value = await navigator.push(route);
    // Callers own text controllers; keep them alive through the exit frames.
    await route.completed;
    _dialogFocusNodes.remove(dialogFocus);
    dialogFocus.dispose();
    if (mounted) {
      _dismissKeyboard();
      _dialogFocusNodes.lastOrNull?.requestFocus();
      _updateReading();
    }
    return value;
  }

  Future<void> _openLink(String value) async {
    _dismissKeyboard();
    try {
      await PlatformBridge.openUrl(value);
    } on Object catch (error) {
      _toast(userError(error, fallback: '无法打开链接，请重试'));
    }
  }

  Future<void> _send() async {
    if (_saving ||
        _addingAttachments ||
        !inbox.ready ||
        !lan.ready ||
        (_composer.text.trim().isEmpty &&
            inbox.store.draftAttachments.isEmpty) ||
        (_composer.value.composing.isValid &&
            !_composer.value.composing.isCollapsed)) {
      return;
    }
    final text = _composer.text;
    final conversation = inbox.conversationId;
    final quote = inbox.store.draftQuotes[conversation];
    setState(() => _saving = true);
    try {
      await inbox.addText(text, conversation: conversation, quote: quote);
      if (text.trim().isNotEmpty &&
          identical(inbox.store.draftQuotes[conversation], quote)) {
        await inbox.setDraftQuote(null, conversation: conversation);
      }
      if (mounted &&
          inbox.conversationId == conversation &&
          _composer.text == text) {
        _composer.clear();
      } else if (inbox.store.drafts[conversation] == text) {
        inbox.store.drafts[conversation] = '';
      }
      await inbox.sendDraftAttachments(
        conversation: conversation,
        quote: text.trim().isEmpty ? quote : null,
      );
      if (text.trim().isEmpty &&
          identical(inbox.store.draftQuotes[conversation], quote)) {
        await inbox.setDraftQuote(null, conversation: conversation);
      }
      if (mounted && inbox.conversationId == conversation) {
        _revealSentMessage();
      }
    } on Object catch (e) {
      _toast(userError(e, fallback: '发送失败，请重试'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _rebuild(VoidCallback callback) => setState(callback);

  void _revealSentMessage() {
    if (_locatedMessage != null) _leaveLocation(latest: true);
    _scrollToLatest();
  }

  Future<void> _files(Iterable<String> paths, {String? conversation}) async {
    if (_saving || _addingAttachments) return;
    setState(() => _addingAttachments = true);
    final target = conversation ?? inbox.conversationId;
    try {
      for (final path in paths) {
        await inbox.stageFile(path, conversation: target);
      }
      if (mounted &&
          inbox.conversationId == target &&
          AppLayout.desktop(context)) {
        _focus.requestFocus();
      }
    } on Object catch (e) {
      _toast(userError(e, fallback: '部分附件添加失败，请重试'));
    } finally {
      if (mounted) setState(() => _addingAttachments = false);
    }
  }

  Future<void> _paste() async {
    if (_saving || _addingAttachments || !inbox.ready || !lan.ready) return;
    final conversation = inbox.conversationId;
    final original = _composer.value;
    setState(() => _addingAttachments = true);
    try {
      final image = await PlatformBridge.readClipboardImage();
      if (image != null) {
        await inbox.pasteImage(image, conversation: conversation);
        if (mounted && inbox.conversationId == conversation) {
          _focus.requestFocus();
        }
        return;
      }
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted || data?.text == null) return;
      if (inbox.conversationId != conversation || _composer.value != original) {
        _toast('输入位置已改变，请在需要的位置重新粘贴');
        return;
      }
      final text = _composer.text;
      final selection = _composer.selection;
      final start = selection.isValid ? selection.start : text.length;
      final end = selection.isValid ? selection.end : text.length;
      final inserted = data!.text!;
      final next = text.replaceRange(start, end, inserted);
      if (next.length > 20000) throw FormatException('文字最多 20000 字');
      _composer.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: start + inserted.length),
      );
    } on Object catch (e) {
      _toast(userError(e, fallback: '粘贴失败，请重试'));
    } finally {
      if (mounted) setState(() => _addingAttachments = false);
    }
  }

  void _newline() {
    final value = _composer.value;
    if (value.composing.isValid && !value.composing.isCollapsed) return;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : start;
    final text = value.text.replaceRange(start, end, '\n');
    if (text.length > 20000) return;
    _composer.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  Future<String?> _showActions({
    required Offset position,
    required List<MessageAction> actions,
    Rect? anchor,
    bool preserveSelection = false,
    bool conversation = false,
  }) async {
    if (!AppLayout.desktop(context)) {
      if (_menuOpen) return null;
      _menuOpen = true;
      inbox.setReadingConversation(null);
      try {
        return await showMessageActions(
          context: context,
          anchor:
              anchor ??
              Rect.fromCenter(center: position, width: 40, height: 40),
          actions: actions,
          preserveFocus: true,
          menuKey: ValueKey(
            conversation
                ? 'conversation-action-palette'
                : 'message-action-palette',
          ),
          barrierLabel: conversation ? '关闭会话操作' : '关闭消息操作',
        );
      } finally {
        _menuOpen = false;
        if (mounted) _updateReading();
      }
    }
    if (!preserveSelection) _dismissKeyboard();
    return _desktopMenu.show(
      context: context,
      position: position,
      takeFocus: !preserveSelection,
      actions: actions,
    );
  }

  Future<void> _itemMenu(
    InboxItem item,
    Offset position, {
    Rect? anchor,
  }) async {
    final selection = _selectedMessage == item.id ? _selectedText : null;
    final viewer = _viewerRoute;
    final action = await _showActions(
      position: position,
      anchor: anchor,
      preserveSelection: selection?.isNotEmpty == true,
      actions: [
        if (item.isFile) ...[
          MessageAction('open', '打开', Icons.open_in_new_outlined),
          MessageAction('folder', '在文件夹中显示', Icons.folder_open_outlined),
          MessageAction('save', '另存为', Icons.save_alt_outlined),
        ] else ...[
          MessageAction(
            'copy',
            selection?.isNotEmpty == true ? '复制选中文字' : '复制文字',
            Icons.content_copy_outlined,
          ),
          if (selection?.isNotEmpty == true)
            MessageAction('copyAll', '复制全部文字', Icons.select_all),
          if (!AppLayout.desktop(context))
            const MessageAction(
              'selectText',
              '选择文本',
              Icons.text_fields_rounded,
            ),
        ],
        const MessageAction('quote', '引用', Icons.format_quote_rounded),
        if (lan.identityReady && item.originId == lan.identity.id)
          const MessageAction('details', '同步详情', Icons.info_outline_rounded),
        MessageAction(
          'favorite',
          inbox.isFavorite(item.id) ? '取消收藏' : '收藏',
          inbox.isFavorite(item.id) ? Icons.star : Icons.star_border,
        ),
        if (viewer == null)
          const MessageAction('select', '多选', Icons.checklist_rounded),
        MessageAction('delete', '删除', Icons.delete_outline, destructive: true),
      ],
    );
    // Dismissal is deliberately passive: the click that dismissed this menu
    // may have already focused the editor or opened another message's menu.
    if (!mounted || action == null) return;
    if (action == 'quote') {
      try {
        await inbox.setDraftQuote(MessageQuote.fromItem(item));
      } on Object catch (error) {
        _toast(userError(error, fallback: '引用未保存，请重试'));
      }
      return;
    }
    if (action == 'selectText') {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        requestFocus: false,
        showDragHandle: true,
        useSafeArea: true,
        builder: (context) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .6,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr(context, '选择文本'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      item.text,
                      key: const ValueKey('message-selectable-text'),
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: item.text)),
                  icon: const Icon(Icons.copy_outlined),
                  label: Text(tr(context, '复制全部文字')),
                ),
              ],
            ),
          ),
        ),
      );
      return;
    }
    if (action == 'select') {
      _beginSelection(item.id);
      return;
    }
    if (action == 'favorite') {
      await _favoriteMessages([item.id], !inbox.isFavorite(item.id));
      return;
    }
    if (action == 'details') {
      final entry = await inbox.store.loadEntry(item.id);
      if (entry != null) await _copyDetails(entry);
    }
    if (action == 'open') await _open(item);
    if (action == 'save') await _saveAs(item);
    if (action == 'folder') {
      try {
        final file = inbox.store.blob(item.digest);
        if (!await file.exists()) throw const FileSystemException('文件尚未下载完成');
        await PlatformBridge.showInFolder(file.path);
      } on Object catch (error) {
        _toast(userError(error, fallback: '无法打开文件夹，请重试'));
      }
    }
    if (action == 'delete') {
      if (!mounted) return;
      if (inbox.linkFavoriteDeletion && inbox.isFavorite(item.id)) {
        final confirmed = await _dialog<bool>(
          context: context,
          builder: (_) => AppConfirmDialog(
            title: tr(context, '删除消息及对应收藏？'),
            confirmLabel: tr(context, '删除'),
            message: tr(context, '已开启联动删除，此消息及对应收藏都会移至回收站。'),
          ),
        );
        if (!mounted || confirmed != true) return;
      }
      try {
        await inbox.deleteItem(item);
        if (mounted && viewer != null && viewer.isCurrent) {
          Navigator.pop(context);
        }
        if (mounted) {
          showAppMessage(
            context,
            '已删除，其他设备上线后也会同步删除',
            duration: const Duration(seconds: 1),
            action: SnackBarAction(
              label: tr(context, inbox.linkFavoriteDeletion ? '恢复消息' : '撤销'),
              onPressed: () async {
                try {
                  await inbox.restoreItem(item);
                } on Object catch (error) {
                  _toast(userError(error, fallback: '恢复失败，请重试'));
                }
              },
            ),
          );
        }
      } on Object catch (error) {
        _toast(userError(error, fallback: '删除失败，请重试'));
      }
    }
    if (action == 'copy' || action == 'copyAll') {
      await Clipboard.setData(
        ClipboardData(
          text: action == 'copy' && selection?.isNotEmpty == true
              ? selection!
              : item.text,
        ),
      );
    }
  }

  Future<void> _pick(bool media) async {
    if (_choosingAttachments || _addingAttachments || _saving) return;
    final conversation = inbox.conversationId;
    final restore =
        _focus.hasFocus && MediaQuery.viewInsetsOf(context).bottom > 0;
    _holdComposerPosition();
    setState(() => _choosingAttachments = true);
    try {
      Future<List<XFile>> choose() => AppFilePicker.openFiles(
        acceptedTypeGroups: media
            ? [
                XTypeGroup(
                  label: tr(context, '图片与视频'),
                  extensions: [
                    'png',
                    'jpg',
                    'jpeg',
                    'webp',
                    'gif',
                    'heic',
                    'mp4',
                    'mov',
                    'mkv',
                    'webm',
                  ],
                  mimeTypes: ['image/*', 'video/*'],
                ),
              ]
            : [],
      );
      final files = await choose();
      if (mounted && files.isNotEmpty) {
        final selected = AppLayout.desktop(context)
            ? files
            : await Navigator.of(context).push<List<XFile>>(
                MaterialPageRoute(
                  builder: (_) =>
                      AttachmentSelectionPage(files: files, onAdd: choose),
                ),
              );
        if (mounted && selected != null) {
          await _files(selected.map((f) => f.path), conversation: conversation);
        }
      }
    } on Object catch (e) {
      _toast(userError(e, fallback: '无法选择文件，请重试'));
    } finally {
      if (mounted) {
        setState(() => _choosingAttachments = false);
        if (restore && !_attachmentPanel) {
          _focus.requestFocus();
          unawaited(
            SystemChannels.textInput.invokeMethod<void>('TextInput.show'),
          );
        }
        _releaseComposerPosition();
      }
    }
  }

  Future<void> _attachments() async {
    final opening = !_attachmentPanel;
    setState(() => _attachmentPanel = opening);
    if (opening) {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } else {
      _focus.requestFocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    }
  }

  Widget _attachmentOptions() {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final height = (_keyboardHeight - inset).clamp(
      0.0,
      MediaQuery.sizeOf(context).height * .42,
    );
    return SizedBox(
      key: const ValueKey('attachment-panel'),
      height: height,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final option in [
              (true, '图片与视频', Icons.photo_library_outlined),
              (false, '文件', Icons.folder_open_rounded),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 24),
                child: Column(
                  children: [
                    SizedBox.square(
                      dimension: 68,
                      child: FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          backgroundColor: palette.surface,
                          padding: EdgeInsets.zero,
                        ),
                        onPressed: _choosingAttachments || _addingAttachments
                            ? null
                            : () => _pick(option.$1),
                        child: Icon(option.$3, size: 30),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      tr(context, option.$2),
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(InboxItem item) async {
    if (_openingFile) return;
    _openingFile = true;
    _desktopMenu.close();
    _holdComposerPosition();
    final restore =
        !AppLayout.desktop(context) &&
        _focus.hasFocus &&
        MediaQuery.viewInsetsOf(context).bottom > 0;
    if (!restore) _dismissKeyboard();
    try {
      final file = item.kind == MessageKind.image
          ? inbox.store.blob(item.digest)
          : await inbox.store.fileForOpening(item);
      if (!mounted) return;
      if (item.kind == MessageKind.image) {
        final route = PageRouteBuilder<void>(
          opaque: !restore,
          requestFocus: !restore,
          pageBuilder: (_, _, _) => ImageViewer(
            file: file,
            name: item.name,
            preserveEditorFocus: restore,
            onMenu: (position) => _itemMenu(item, position),
          ),
          transitionsBuilder: (_, animation, _, child) =>
              FadeTransition(opacity: animation, child: child),
          transitionDuration: AppMotion.duration(context, 160),
          reverseTransitionDuration: AppMotion.duration(context, 130),
        );
        _viewerRoute = route;
        await Navigator.of(context).push(route);
        await route.completed;
        if (identical(_viewerRoute, route)) _viewerRoute = null;
        if (mounted && restore) {
          _focus.requestFocus();
          unawaited(
            SystemChannels.textInput.invokeMethod<void>('TextInput.show'),
          );
        }
      } else {
        await PlatformBridge.openFile(file.path);
      }
    } on Object catch (e) {
      _toast(userError(e, fallback: '无法打开附件，请重试'));
    } finally {
      _openingFile = false;
      _releaseComposerPosition();
    }
  }

  Future<void> _saveAs(InboxItem item) async {
    try {
      final file = await inbox.store.fileForExport(item);
      if (Platform.isAndroid) {
        if (await PlatformBridge.exportFile(file.path, item.name)) {
          _toast('文件已保存');
        }
      } else {
        final location = await getSaveLocation(suggestedName: item.name);
        if (location != null) {
          await file.copy(location.path);
          _toast('文件已保存');
        }
      }
    } on Object catch (e) {
      _toast(userError(e, fallback: '文件保存失败，请重试'));
    }
  }

  bool get _touchNavigation =>
      !AppLayout.desktop(context) && !AppLayout.split(context);

  void _transitionReading(VoidCallback change) {
    _readingTransitions++;
    inbox.setReadingConversation(null);
    try {
      change();
    } finally {
      _readingTransitions--;
      _updateReading();
    }
  }

  void _selectDesktopSection(MobileSection section) => _transitionReading(() {
    if (_selection.busy || section == _mobileSection) return;
    if (_mobileSection == MobileSection.conversations) _rememberReadingOffset();
    _selection.clear();
    _desktopMenu.close();
    _dismissKeyboard();
    setState(() {
      _mobileSection = section;
      _openedDesktopSections.add(section);
    });
    _updateReading();
  });

  void _selectMobileSection(MobileSection section) => _transitionReading(() {
    if (_selection.busy) return;
    _selection.clear();
    _desktopMenu.close();
    _dismissKeyboard();
    setState(() {
      _mobileChat = false;
      _searchOpen = false;
      _mobileSection = section;
    });
    _updateReading();
  });

  Future<void> _devices() => _openSettings(SettingsPage.devices);

  Future<void> _transfers() => _openSettings(SettingsPage.transfers);

  Future<void> _trash() async {
    if (AppLayout.desktop(context)) {
      _selectDesktopSection(MobileSection.trash);
    } else if (_touchNavigation) {
      _selectMobileSection(MobileSection.trash);
    } else {
      await _dialog<void>(
        context: context,
        builder: (_) => RecentlyDeletedPanel(inbox: inbox),
      );
    }
  }

  void _favoriteBackChanged(VoidCallback? handler) {
    if (!mounted) return;
    _favoriteBack = handler;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  Future<void> _syncProblems() => _dialog<void>(
    context: context,
    builder: (_) => SyncIssuesPanel(
      inbox: inbox,
      onDevices: () {
        Navigator.pop(context);
        unawaited(_devices());
      },
      onTransfers: () {
        Navigator.pop(context);
        unawaited(_transfers());
      },
    ),
  );

  Future<void> _settings() => _openSettings(SettingsPage.preferences);

  Future<void> _copyDetails(InboxEntry entry) => _dialog<void>(
    context: context,
    builder: (_) => SyncDetails(
      inbox: inbox,
      entry: entry,
      onDevices: () {
        Navigator.pop(context);
        unawaited(_devices());
      },
      onTransfers: () {
        Navigator.pop(context);
        unawaited(_transfers());
      },
    ),
  );

  Future<void> _openSettings(SettingsPage page) => _dialog<void>(
    context: context,
    builder: (_) => SettingsPanel(inbox: inbox, initialPage: page),
  );

  void _openConversation(String id) => _transitionReading(() {
    if (_selection.busy) return;
    _locatedFromFavorites = false;
    _locatedFromQuote = false;
    _selection.clear();
    _desktopMenu.close();
    _selectedMessage = null;
    _selectedText = null;
    _dismissKeyboard();
    _locatedMessage = null;
    _locatedQuery = '';
    _searchOpen = false;
    inbox.selectConversation(id);
    setState(() {
      _mobileChat = true;
      _mobileSection = MobileSection.conversations;
    });
    _scrollToOffset(_readingOffsets[id] ?? 0);
  });

  Future<void> _newConversation() async {
    if (_creatingConversation || !inbox.ready || _selection.busy) return;
    final defaultName = tr(context, '新建会话');
    _creatingConversation = true;
    await _finishRename();
    try {
      final conversation = await inbox.createConversation(defaultName);
      if (!mounted) return;
      _openConversation(conversation.id);
      _beginRename(conversation.id);
    } on Object catch (error) {
      _toast(userError(error, fallback: '创建失败，请重试'));
    } finally {
      _creatingConversation = false;
    }
  }

  void _beginRename(String id) {
    final name =
        _pendingConversationNames[id] ??
        inbox.conversations.firstWhere((c) => c.id == id).name;
    _conversationName.value = TextEditingValue(
      text: name,
      selection: TextSelection(baseOffset: 0, extentOffset: name.length),
    );
    setState(() => _editingConversation = id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editingConversation == id) {
        _conversationNameFocus.requestFocus();
      }
    });
  }

  void _conversationNameFocusChanged() {
    if (!_conversationNameFocus.hasFocus && _editingConversation != null) {
      unawaited(_finishRename());
    }
  }

  Future<void> _finishRename({
    bool cancel = false,
    bool propagateFailure = false,
  }) async {
    final id = _editingConversation;
    if (id == null) return;
    final name = _conversationName.text.trim();
    setState(() => _editingConversation = null);
    _conversationNameFocus.unfocus();
    if (cancel || name.isEmpty) {
      _pendingConversationNames.remove(id);
      return;
    }
    _pendingConversationNames[id] = name;
    try {
      await _savePendingConversationName(id);
    } on Object catch (error) {
      if (mounted &&
          _editingConversation == null &&
          inbox.conversationId == id &&
          _mobileSection == MobileSection.conversations &&
          _pendingConversationNames[id] == name) {
        _beginRename(id);
      }
      _toast(userError(error, fallback: '重命名失败，请重试'));
      if (propagateFailure) rethrow;
    }
  }

  Future<void> _savePendingConversationName(String id) async {
    final running = _conversationNameWrites[id];
    if (running != null) {
      await running;
      if (_pendingConversationNames.containsKey(id)) {
        await _savePendingConversationName(id);
      }
      return;
    }
    final name = _pendingConversationNames[id];
    if (name == null) return;
    final previous = inbox.conversations.where((c) => c.id == id).firstOrNull;
    if (previous == null || previous.name == name) {
      _pendingConversationNames.remove(id);
      return;
    }
    final operation = () async {
      await inbox.renameConversation(id, name);
      if (_pendingConversationNames[id] == name) {
        _pendingConversationNames.remove(id);
      }
    }();
    _conversationNameWrites[id] = operation;
    try {
      await operation;
    } finally {
      if (identical(_conversationNameWrites[id], operation)) {
        _conversationNameWrites.remove(id);
      }
    }
  }

  Future<void> _commitConversationNames() async {
    await _finishRename(propagateFailure: true);
    for (final id in _pendingConversationNames.keys.toList()) {
      await _savePendingConversationName(id);
    }
    await Future.wait(_conversationNameWrites.values.toList());
  }

  Future<void> _conversationMenu(
    String? id,
    Offset point, {
    Rect? anchor,
  }) async {
    _dismissKeyboard();
    final preference = id == null ? null : inbox.store.preference(id);
    final unread = id != null && inbox.isUnread(id);
    final action = await _showActions(
      position: point,
      anchor: anchor,
      conversation: true,
      actions: id == null
          ? [const MessageAction('new', '新建会话', Icons.add)]
          : [
              MessageAction(
                'pin',
                preference!.pinnedAt == null ? '置顶' : '取消置顶',
                Icons.push_pin_outlined,
              ),
              MessageAction(
                'unread',
                unread ? '标为已读' : '标为未读',
                unread
                    ? Icons.mark_chat_read_outlined
                    : Icons.mark_chat_unread_outlined,
              ),
              const MessageAction('rename', '重命名', Icons.edit_outlined),
              const MessageAction('avatar', '更换头像', Icons.face_outlined),
              const MessageAction(
                'background',
                '会话背景颜色',
                Icons.palette_outlined,
              ),
              const MessageAction(
                'deleteConversation',
                '删除',
                Icons.delete_outline,
                destructive: true,
              ),
            ],
    );
    if (!mounted || action == null) return;
    try {
      if (action == 'new') {
        await _newConversation();
        return;
      }
      if (id == null) return;
      if (action == 'rename') {
        _openConversation(id);
        _beginRename(id);
        return;
      }
      if (action == 'pin') {
        await inbox.setConversationPinned(id, preference!.pinnedAt == null);
      }
      if (action == 'unread') await inbox.setConversationUnread(id, !unread);
      if (action == 'background') {
        if (mounted) await _conversationDialogs.background(context, id);
      }
      if (action == 'avatar' && mounted) {
        await _conversationDialogs.avatar(context, id);
      }
      if (action == 'deleteConversation') {
        if (mounted) await _conversationDialogs.delete(context, id);
      }
    } on Object catch (error) {
      _toast(userError(error, fallback: '会话设置保存失败，请重试'));
    }
  }

  void _updateReading() {
    if (!mounted) return;
    final visible =
        _readingTransitions == 0 &&
        !widget.interactionsBlocked &&
        _foreground &&
        _atLatest.value &&
        _dialogFocusNodes.isEmpty &&
        !_menuOpen &&
        _mobileSection == MobileSection.conversations &&
        (AppLayout.split(context) || _mobileChat) &&
        !_searchOpen &&
        !_selection.active &&
        _locatedMessage == null &&
        (ModalRoute.of(context)?.isCurrent ?? false);
    inbox.setReadingConversation(visible ? inbox.conversationId : null);
  }

  Future<void> _restart() async {
    if (lan.error?.startsWith('本地记录保存失败：') == true) {
      await lan.retrySave();
      return;
    }
    final failure = inbox.error;
    if (inbox.ready &&
        failure != null &&
        (failure.startsWith('草稿保存失败：') || failure.startsWith('会话选择保存失败：'))) {
      await inbox.retryLocalSave();
      return;
    }
    if (!lan.ready) await lan.start();
    if (!inbox.ready) await inbox.start();
    if (inbox.ready && lan.ready) {
      inbox.error = null;
      lan.error = null;
      inbox.requestSync();
      await PlatformBridge.drainShares();
    }
    _update();
  }

  Widget _empty() => AppEmptyState(
    title: '给自己发条消息吧',
    icon: Icons.chat_bubble_outline_rounded,
    description: '文字、图片和文件会保存在本机，绑定设备后自动同步。',
    action: inbox.syncTargets.isEmpty
        ? TextButton(onPressed: _devices, child: Text(tr(context, '连接设备')))
        : null,
  );

  Widget _compose(bool wide) => ChatComposer(
    inbox: inbox,
    controller: _composer,
    focusNode: _focus,
    editorMenuKey: _editorMenuKey,
    hasText: _hasText,
    saving: _saving,
    preparing: _addingAttachments,
    picking: _choosingAttachments,
    wide: wide,
    onSend: _send,
    onPaste: _paste,
    onNewline: _newline,
    onPick: _pick,
    onAttachments: _attachments,
    onEdit: () {
      if (_attachmentPanel) setState(() => _attachmentPanel = false);
    },
    onCancelQuote: () => unawaited(
      inbox
          .setDraftQuote(null)
          .catchError(
            (Object e) => _toast(userError(e, fallback: '引用未保存，请重试')),
          ),
    ),
    attachmentPanel: _attachmentPanel && !wide ? _attachmentOptions() : null,
    selectionActions: _selection.active
        ? MessageSelectionBar(
            panel: true,
            selection: _selection,
            onAll: _selectAllMessages,
            onDelete: _deleteSelection,
            onFavorite: () => _favoriteMessages(_selection.ids.toList(), true),
            onExport: _exportSelection,
          )
        : null,
  );

  Widget _conversationList({required bool mobile}) => ConversationList(
    inbox: inbox,
    mobile: mobile,
    onOpen: _openConversation,
    onMenu: _conversationMenu,
  );

  Widget _sidebar({bool mobile = false, bool showNavigation = true}) {
    if (_globalSearch.query.isEmpty) {
      _globalSearch.conversationId = inbox.conversationId;
    }
    return ChatSidebar(
      inbox: inbox,
      compact: mobile,
      showNavigation: showNavigation,
      keyboardVisible: MediaQuery.viewInsetsOf(context).bottom > 0,
      search: MessageSearchPanel(
        key: const ValueKey('sidebar-search'),
        inbox: inbox,
        session: _globalSearch,
        idle: _conversationList(mobile: mobile),
        onSelected: (result) => _selectSearchResult(result, _globalSearch),
        trailing: IconButton(
          tooltip: tr(context, '新建会话'),
          onPressed: inbox.ready ? _newConversation : null,
          icon: const Icon(Icons.add_circle_outline, size: 21),
        ),
      ),
      onSettings: _settings,
      onProfile: () => _openSettings(SettingsPage.profile),
      onDevices: _devices,
      onTransfers: _transfers,
      onFavorites: _favorites,
      onTrash: _trash,
    );
  }

  Widget _syncNotice() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const ShareImportNotice(),
      SyncAttentionNotice(inbox: inbox, onOpen: _syncProblems),
    ],
  );

  Widget _mobileHome() => MobileHome(
    inbox: inbox,
    section: _mobileSection,
    keyboardVisible: MediaQuery.viewInsetsOf(context).bottom > 0,
    onSection: _selectMobileSection,
    onProfile: () => _openSettings(SettingsPage.profile),
    onSettings: _settings,
    notice: _syncNotice(),
    child: switch (_mobileSection) {
      MobileSection.conversations => _sidebar(mobile: true),
      MobileSection.devices => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: DevicePanel(dialogs: _deviceDialogs, embedded: true),
      ),
      MobileSection.transfers => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: TransferDialog(inbox: inbox, embedded: true),
      ),
      MobileSection.favorites => FavoritesPanel(
        inbox: inbox,
        embedded: true,
        onLocate: _locateFavorite,
        onBackHandlerChanged: _favoriteBackChanged,
      ),
      MobileSection.trash => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: RecentlyDeletedPanel(inbox: inbox, embedded: true),
      ),
    },
  );

  Widget _chatHeader(bool wide) => ChatHeader(
    inbox: inbox,
    wide: wide,
    title: _editingConversation == inbox.conversationId
        ? TextField(
            key: const ValueKey('conversation-name'),
            controller: _conversationName,
            focusNode: _conversationNameFocus,
            maxLength: 40,
            maxLines: 1,
            textInputAction: TextInputAction.done,
            style: TextStyle(
              fontSize: AppTypography.conversationTitle,
              color: palette.text,
            ),
            decoration: const InputDecoration(
              counterText: '',
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 2),
              border: UnderlineInputBorder(),
            ),
            onSubmitted: (_) => _finishRename(),
            onTapOutside: (_) => _finishRename(),
          )
        : null,
    onBack: () {
      _selectMobileSection(MobileSection.conversations);
    },
    onSearch: _openSearch,
    onTransfers: _transfers,
    onDevices: _devices,
    onSettings: _settings,
    onSelect: inbox.itemsIn(inbox.conversationId).isEmpty
        ? null
        : () => _beginSelection(),
  );

  Widget _messageRow(
    InboxEntry entry, {
    required bool wide,
    required MessagePresentation presentation,
    String highlight = '',
  }) => SelectableMessage(
    selection: _selection,
    id: entry.item.id,
    child: MessageTile(
      inbox: inbox,
      entry: entry,
      showTime: presentation.showTime,
      showIdentity: presentation.showIdentity,
      showStatus: presentation.showStatus,
      wide: wide,
      highlightQuery: highlight,
      onOpen: _open,
      onLink: _openLink,
      onMenu: _itemMenu,
      onStatus: () => _copyDetails(entry),
      onQuote: (quote) async {
        InboxEntry? original;
        try {
          original = await inbox.store.loadEntry(quote.id);
          if (original != null) await inbox.store.loadContext(quote.id);
        } on Object catch (error) {
          _toast(userError(error, fallback: '搜索失败，请重试'));
          return;
        }
        if (!mounted) return;
        if (original == null) {
          _toast('原消息已删除');
          return;
        }
        _rememberReadingOffset();
        setState(() {
          _locatedFromQuote = true;
          _locatedMessage = quote.id;
          _locatedQuery = '';
        });
      },
      onSelectionChanged: (text) {
        if (text?.isNotEmpty == true) {
          _selectedMessage = entry.item.id;
          _selectedText = text;
        } else if (_selectedMessage == entry.item.id) {
          _selectedMessage = null;
          _selectedText = null;
        }
      },
    ),
  );

  Widget _history(bool wide) {
    final key = (
      inbox.ready,
      lan.ready,
      lan.identityReady,
      lan.starting,
      (
        inbox.store.contentRevision,
        inbox.store.profilesRevision,
        inbox.store.favoritesRevision,
        inbox.store.language,
        inbox.ready ? 0 : inbox.loadingRecords,
        inbox.ready ? 0 : inbox.totalRecords,
      ),
      inbox.conversationId,
      palette.blend,
      wide,
      inbox.endpoints.map((e) => e.key).join('|'),
      lan.peers.values.map((p) => '${p.id}:${p.name}:${p.platform}').join('|'),
    );
    if (_historyKey == key && _historyWidget != null) return _historyWidget!;
    _historyKey = key;
    Widget child;
    if (!inbox.ready) {
      child = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tr(
                context,
                inbox.totalRecords > 1000
                    ? '正在打开聊天记录… {loaded}/{total}'
                    : '正在打开聊天记录…',
                {'loaded': inbox.loadingRecords, 'total': inbox.totalRecords},
              ),
              style: TextStyle(color: muted),
            ),
            if (!lan.starting && (lan.error != null || inbox.error != null))
              TextButton(onPressed: _restart, child: Text(tr(context, '重试启动'))),
          ],
        ),
      );
    } else {
      var items = inbox.itemsIn(inbox.conversationId);
      if (items.isEmpty) {
        child = inbox.store.loadingHistory(inbox.conversationId)
            ? const Center(child: CircularProgressIndicator())
            : _empty();
      } else {
        child = ChatHistoryView(
          entries: items,
          controller: _scroll,
          rowKeys: _rowKeys,
          wide: wide,
          onLoadOlder: inbox.store.hasOlderHistory(inbox.conversationId)
              ? () => inbox.loadHistory(inbox.conversationId, older: true)
              : null,
          rowBuilder: (entry, presentation) =>
              _messageRow(entry, wide: wide, presentation: presentation),
        );
      }
    }
    return _historyWidget = RepaintBoundary(
      key: _historyViewport,
      child: child,
    );
  }

  Widget _dropArea(Widget child) => DropTarget(
    key: ValueKey('chat-drop-area'),
    enable:
        Theme.of(context).platform == TargetPlatform.windows &&
        inbox.ready &&
        lan.ready &&
        !_saving &&
        !_selection.active &&
        !_addingAttachments &&
        (ModalRoute.of(context)?.isCurrent ?? false),
    onDragEntered: (_) {
      _desktopMenu.close();
      setState(() => _dropping = true);
    },
    onDragExited: (_) {
      if (_dropping) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _dropping) setState(() => _dropping = false);
        });
      }
    },
    onDragDone: (details) {
      setState(() => _dropping = false);
      unawaited(_files(details.files.map((f) => f.path)));
    },
    child: Stack(
      children: [
        Positioned.fill(child: child),
        if (_dropping)
          Positioned.fill(
            child: Container(
              color: palette.surface.withValues(alpha: .95),
              child: Center(
                child: Text(
                  tr(context, '松开，添加到待发送区'),
                  style: TextStyle(
                    fontSize: AppTypography.title,
                    color: brandGreen,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _historyPane(bool wide) => _locatedMessage != null
      ? Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              color: palette.sidebar,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton.icon(
                      onPressed: () => _locatedFromQuote
                          ? _leaveLocation()
                          : _locatedFromFavorites
                          ? _favorites()
                          : _openSearch(resume: true),
                      icon: const Icon(Icons.arrow_back_rounded, size: 18),
                      label: Text(
                        tr(
                          context,
                          _locatedFromQuote
                              ? '返回会话'
                              : _locatedFromFavorites
                              ? '返回收藏'
                              : '返回搜索结果',
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _leaveLocation(latest: true),
                      child: Text(tr(context, '回到最新')),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: MessageContext(
                key: ValueKey(_locatedMessage),
                entries: inbox.store.pagedHistory
                    ? inbox.store.contextEntries
                    : inbox.itemsIn(inbox.conversationId),
                onOlder:
                    inbox.store.pagedHistory && inbox.store.moreOlderContext
                    ? () => inbox.extendMessageContext(newer: false)
                    : null,
                onNewer:
                    inbox.store.pagedHistory && inbox.store.moreNewerContext
                    ? () => inbox.extendMessageContext(newer: true)
                    : null,
                targetId: _locatedMessage!,
                wide: wide,
                rowBuilder: (entry, presentation) => _messageRow(
                  entry,
                  wide: wide,
                  presentation: presentation,
                  highlight: _locatedQuery,
                ),
              ),
            ),
          ],
        )
      : Stack(
          children: [
            Positioned.fill(child: _history(wide)),
            Positioned(
              bottom: 12,
              right: wide ? 22 : 14,
              child: ValueListenableBuilder<bool>(
                valueListenable: _atLatest,
                builder: (_, latest, _) => latest
                    ? const SizedBox.shrink()
                    : Material(
                        color: palette.surface,
                        elevation: 2,
                        borderRadius: AppCorners.border,
                        child: TextButton.icon(
                          onPressed: () => _scrollToLatest(animate: true),
                          icon: Icon(
                            Icons.keyboard_double_arrow_down,
                            size: 18,
                          ),
                          label: Text(tr(context, '回到最新')),
                          style: TextButton.styleFrom(
                            foregroundColor: brandGreen,
                            textStyle: TextStyle(
                              fontSize: AppTypography.caption,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ],
        );

  Widget _chatBody(bool wide) => _searchOpen
      ? MessageSearchPanel(
          key: ObjectKey(_chatSearch),
          inbox: inbox,
          session: _chatSearch!,
          autofocus: true,
          onClose: _closeSearch,
          onSelected: (result) => _selectSearchResult(result, _chatSearch!),
        )
      : _dropArea(
          ChatBodyLayout(
            inbox: inbox,
            wide: wide,
            history: _historyPane(wide),
            composer: _compose(wide),
          ),
        );

  Widget _desktopChat(bool wide) => Row(
    children: [
      if (wide) _sidebar(showNavigation: false),
      Expanded(
        child: Column(
          children: [
            if (!wide && !_mobileChat)
              Expanded(child: _sidebar(mobile: true, showNavigation: false))
            else ...[
              if (!_searchOpen || wide) _chatHeader(wide),
              _syncNotice(),
              Expanded(child: _chatBody(wide)),
            ],
          ],
        ),
      ),
    ],
  );

  Widget _desktopPanel(MobileSection section) => Material(
    color: palette.canvas,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 68,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: palette.divider, width: .6),
            ),
          ),
          child: Text(
            tr(context, section.title),
            style: TextStyle(
              fontSize: AppTypography.conversationTitle,
              fontWeight: FontWeight.w500,
              color: palette.text,
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            child: switch (section) {
              MobileSection.favorites => FavoritesPanel(
                inbox: inbox,
                embedded: true,
                onLocate: _locateFavorite,
                onBackHandlerChanged: _favoriteBackChanged,
              ),
              MobileSection.devices => DevicePanel(
                dialogs: _deviceDialogs,
                embedded: true,
              ),
              MobileSection.transfers => TransferDialog(
                inbox: inbox,
                embedded: true,
              ),
              MobileSection.conversations => const SizedBox.shrink(),
              MobileSection.trash => RecentlyDeletedPanel(
                inbox: inbox,
                embedded: true,
                active: _mobileSection == MobileSection.trash,
              ),
            },
          ),
        ),
      ],
    ),
  );

  Widget _desktopWorkspace(bool wide, String? error) => Row(
    children: [
      DesktopNavigation(
        inbox: inbox,
        section: _mobileSection,
        onSection: _selectDesktopSection,
        onSettings: _settings,
        onProfile: () => _openSettings(SettingsPage.profile),
      ),
      Expanded(
        child: Column(
          children: [
            if (error != null)
              MaterialBanner(
                content: Text(
                  tr(context, userError(error, fallback: '操作失败，请重试')),
                ),
                actions: [
                  TextButton(
                    onPressed: _restart,
                    child: Text(tr(context, '重试')),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      inbox.error = null;
                      lan.error = null;
                    }),
                    child: Text(tr(context, '知道了')),
                  ),
                ],
              ),
            Expanded(
              child: IndexedStack(
                index: _mobileSection.index,
                children: [
                  for (final section in MobileSection.values)
                    TickerMode(
                      enabled: _mobileSection == section,
                      child: FocusScope(
                        canRequestFocus: _mobileSection == section,
                        child: KeyedSubtree(
                          key: ValueKey('desktop-page-${section.name}'),
                          child: !_openedDesktopSections.contains(section)
                              ? const SizedBox.shrink()
                              : section == MobileSection.conversations
                              ? _desktopChat(wide)
                              : _desktopPanel(section),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateReading());
    final wide = AppLayout.split(context);
    final restoredPanel =
        !AppLayout.desktop(context) &&
        _mobileSection != MobileSection.conversations;
    final listOnly = restoredPanel || (!wide && !_mobileChat);
    final error = inbox.error ?? lan.error;
    return PopScope(
      canPop:
          !widget.interactionsBlocked &&
          !_attachmentPanel &&
          !_selection.active &&
          !_searchOpen &&
          !(_mobileSection == MobileSection.favorites &&
              _favoriteBack != null) &&
          ((wide && !restoredPanel) ||
              (!_mobileChat &&
                  ((!_touchNavigation && !restoredPanel) ||
                      _mobileSection == MobileSection.conversations))),
      onPopInvokedWithResult: (didPop, _) {
        if (widget.interactionsBlocked) return;
        if (!didPop && _attachmentPanel) {
          _dismissKeyboard();
        } else if (!didPop && _selection.active) {
          _selection.clear();
        } else if (!didPop && _searchOpen) {
          _closeSearch();
        } else if (!didPop &&
            _mobileSection == MobileSection.favorites &&
            _favoriteBack != null) {
          _favoriteBack!();
        } else if (!didPop && (!wide || restoredPanel)) {
          _selectMobileSection(MobileSection.conversations);
        }
      },
      child: Focus(
        focusNode: _pageFocus,
        autofocus: true,
        child: MediaQuery(
          data: _composerViewport(),
          child: Scaffold(
            body: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: AppLayout.desktop(context) ? _dismissKeyboard : null,
              child: SafeArea(
                child: AppLayout.desktop(context)
                    ? _desktopWorkspace(wide, error)
                    : Row(
                        children: [
                          if (wide) _sidebar(),
                          Expanded(
                            child: PageReveal(
                              identity: listOnly,
                              enabled: !wide,
                              child: Column(
                                children: [
                                  if (error != null)
                                    MaterialBanner(
                                      content: Text(
                                        tr(
                                          context,
                                          userError(
                                            error,
                                            fallback: '操作失败，请重试',
                                          ),
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: _restart,
                                          child: Text(tr(context, '重试')),
                                        ),
                                        TextButton(
                                          onPressed: () => setState(() {
                                            lan.error = null;
                                            inbox.error = null;
                                          }),
                                          child: Text(tr(context, '知道了')),
                                        ),
                                      ],
                                    ),
                                  if (listOnly) ...[
                                    Expanded(
                                      child: _touchNavigation || restoredPanel
                                          ? _mobileHome()
                                          : _sidebar(mobile: true),
                                    ),
                                  ] else ...[
                                    if (!_searchOpen || wide) _chatHeader(wide),
                                    _syncNotice(),
                                    Expanded(child: _chatBody(wide)),
                                  ],
                                ],
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
    );
  }
}
