import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/search_text.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/user_feedback.dart';

class MessageSearchSession {
  MessageSearchSession({
    required this.conversationId,
    this.all = false,
    String query = '',
  }) : input = TextEditingController(text: query);

  String conversationId;
  final TextEditingController input;
  final focus = FocusNode(debugLabel: 'Message search');
  bool all;
  String get query => input.text;
  double offset = 0;

  void dispose() {
    input.dispose();
    focus.dispose();
  }
}

class MessageSearchSelection {
  const MessageSearchSelection(
    this.conversationId, [
    this.entry,
    this.query = '',
  ]);
  final String conversationId;
  final InboxEntry? entry;
  final String query;
}

/// Search stays in the surface that opened it; typing only rebuilds this pane.
class MessageSearchPanel extends StatefulWidget {
  const MessageSearchPanel({
    super.key,
    required this.inbox,
    required this.session,
    required this.onSelected,
    this.onClose,
    this.idle,
    this.trailing,
    this.autofocus = false,
  });
  final InboxController inbox;
  final MessageSearchSession session;
  final ValueChanged<MessageSearchSelection> onSelected;
  final VoidCallback? onClose;
  final Widget? idle, trailing;
  final bool autofocus;

  @override
  State<MessageSearchPanel> createState() => _MessageSearchPanelState();
}

class _MessageSearchPanelState extends State<MessageSearchPanel> {
  late final _scroll = ScrollController(
    initialScrollOffset: widget.session.offset,
  );
  late String _resultQuery = widget.session.query;
  Timer? _pending;
  Object? _resultKey;
  Map<String, String> _conversationNames = {};
  List<Conversation> _names = const [];
  List<InboxEntry> _entries = const [];
  bool _loading = false, _more = false;
  int _generation = 0, _total = 0, _nextOffset = 0;
  String? _error;

  bool get _sidebar => widget.idle != null;

  @override
  void initState() {
    super.initState();
    widget.session.input.addListener(_changed);
    _scroll.addListener(_scrolled);
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.session.focus.requestFocus();
      });
    }
  }

  void _scrolled() {
    widget.session.offset = _scroll.offset;
    if (_scroll.position.extentAfter < 200 && _more && !_loading) _loadMore();
  }

  void _changed() {
    _pending?.cancel();
    final value = widget.session.input.value;
    // Do not scan the history for caret movement or unfinished IME candidates.
    if (value.text == _resultQuery ||
        (value.composing.isValid && !value.composing.isCollapsed)) {
      return;
    }
    if (value.text.trim().isEmpty) {
      _applyQuery();
    } else {
      _pending = Timer(const Duration(milliseconds: 80), _applyQuery);
    }
  }

  void _applyQuery() {
    _pending?.cancel();
    if (!mounted || _resultQuery == widget.session.query) return;
    setState(() => _resultQuery = widget.session.query);
    _resetScroll();
  }

  void _resetScroll() {
    widget.session.offset = 0;
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _refreshResults() {
    final session = widget.session;
    final key = (
      widget.inbox.store.contentRevision,
      widget.inbox.store.conversationsRevision,
      widget.inbox.store.language,
      session.conversationId,
      session.all,
      _resultQuery,
    );
    if (_resultKey == key) return;
    _resultKey = key;
    final conversations = widget.inbox.conversations;
    _conversationNames = {
      for (final value in conversations) value.id: _conversationLabel(value),
    };
    final pattern = searchPattern(_resultQuery);
    _names = pattern == null || !session.all
        ? const []
        : conversations
              .where((value) => pattern.hasMatch(_conversationLabel(value)))
              .toList();
    _entries = const [];
    _total = 0;
    _nextOffset = 0;
    _more = false;
    _error = null;
    final generation = ++_generation;
    if (pattern == null) {
      widget.inbox.cancelMessageSearches(widget.session);
      _loading = false;
      return;
    }
    _loadPage(generation, append: false);
  }

  String _conversationLabel(Conversation value) =>
      value.id == defaultConversationId && value.name == '发给自己'
      ? tr(context, '发给自己')
      : value.name;

  Map<String, dynamic> _query(int offset) {
    final session = widget.session;
    return {
      'query': _resultQuery.trim(),
      if (!session.all) 'conversationId': session.conversationId,
      'offset': offset,
      'limit': 100,
    };
  }

  void _loadPage(int generation, {required bool append}) {
    _loading = true;
    final result = widget.inbox.searchMessages(
      _query(append ? _nextOffset : 0),
      requestGroup: widget.session,
    );
    void apply(Map<String, dynamic> page) {
      final entries = (page['ids'] as List)
          .cast<String>()
          .map(widget.inbox.store.find)
          .whereType<InboxEntry>()
          .toList();
      _entries = append ? [..._entries, ...entries] : entries;
      _total = page['total'] as int;
      _nextOffset = page['nextOffset'] as int;
      _more = page['more'] == true;
      _loading = false;
    }

    if (result is Future<Map<String, dynamic>>) {
      result.then(
        (page) {
          if (mounted && generation == _generation) setState(() => apply(page));
        },
        onError: (Object error) {
          if (mounted && generation == _generation) {
            setState(() {
              _loading = false;
              _error = userError(error, fallback: '搜索失败，请重试');
            });
          }
        },
      );
    } else {
      apply(result);
    }
  }

  void _loadMore() {
    if (_loading || !_more) return;
    setState(() => _loadPage(_generation, append: true));
  }

  @override
  void dispose() {
    _pending?.cancel();
    widget.inbox.cancelMessageSearches(widget.session);
    widget.session.input.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.inbox,
    builder: (context, _) {
      _refreshResults();
      final session = widget.session;
      final palette = ChatPalette.of(context);
      final hasQuery = _resultQuery.trim().isNotEmpty;
      final showResults = !_sidebar || hasQuery;
      final scope = session.all
          ? tr(context, '全部会话')
          : _conversationNames[session.conversationId] ?? tr(context, '原会话');
      return PopScope(
        canPop: !_sidebar || !hasQuery,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _sidebar && hasQuery) {
            session.input.clear();
          }
        },
        child: LayoutBuilder(
          builder: (context, bounds) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: ValueKey(
                          _sidebar
                              ? 'global-conversation-search'
                              : 'message-search-input',
                        ),
                        controller: session.input,
                        focusNode: session.focus,
                        maxLength: 200,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) {
                          _applyQuery();
                          session.focus.unfocus();
                        },
                        style: Theme.of(context).textTheme.bodyMedium,
                        decoration: InputDecoration(
                          hintText: tr(
                            context,
                            session.all ? '搜索会话和消息' : '搜索当前会话',
                          ),
                          hintMaxLines: 1,
                          counterText: '',
                          isDense: true,
                          filled: true,
                          fillColor: palette.canvas,
                          prefixIcon: const Icon(Icons.search, size: 20),
                          prefixIconConstraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 44,
                          ),
                          suffixIconConstraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 44,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 12,
                          ),
                          suffixIcon: ValueListenableBuilder<TextEditingValue>(
                            valueListenable: session.input,
                            builder: (context, value, _) => value.text.isEmpty
                                ? const SizedBox.shrink()
                                : IconButton(
                                    tooltip: tr(context, '清空搜索'),
                                    onPressed: session.input.clear,
                                    icon: const Icon(Icons.close, size: 18),
                                  ),
                          ),
                        ),
                      ),
                    ),
                    if (widget.trailing != null) widget.trailing!,
                    if (widget.onClose != null)
                      IconButton(
                        tooltip: tr(context, '关闭搜索'),
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close_rounded),
                      ),
                  ],
                ),
              ),
              if (showResults)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: (bounds.maxHeight * .4).clamp(0, 160),
                  ),
                  child: SingleChildScrollView(
                    key: const ValueKey('search-controls-scroll'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              for (final all in [true, false])
                                ChoiceChip(
                                  key: ValueKey(
                                    all
                                        ? 'search-scope-all'
                                        : 'search-scope-current',
                                  ),
                                  label: Text(
                                    tr(context, all ? '全部会话' : '当前会话'),
                                  ),
                                  selected: session.all == all,
                                  showCheckmark: false,
                                  visualDensity: VisualDensity.compact,
                                  onSelected: (_) {
                                    setState(() => session.all = all);
                                    _resetScroll();
                                  },
                                ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
                          child: Text(
                            tr(context, '范围：{name}', {'name': scope}),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: !showResults
                    ? widget.idle!
                    : Scrollbar(
                        controller: _scroll,
                        child: ListView.builder(
                          key: const ValueKey('message-search-results'),
                          controller: _scroll,
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          itemCount:
                              1 +
                              _names.length +
                              (_entries.isEmpty ? 1 : _entries.length) +
                              (_more && _entries.isNotEmpty ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  hasQuery
                                      ? '${_names.isEmpty ? '' : '${tr(context, '{count} 个会话', {'count': _names.length})} · '}${tr(context, '{count} 条匹配消息', {'count': _total})}'
                                      : tr(context, '输入关键词，搜索文字、附件名称或会话名称'),
                                  key: const ValueKey('search-result-count'),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              );
                            }
                            if (index <= _names.length) {
                              final conversation = _names[index - 1];
                              return ListTile(
                                key: ValueKey(
                                  'search-conversation-${conversation.id}',
                                ),
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.chat_bubble_outline),
                                title: HighlightedText(
                                  _conversationLabel(conversation),
                                  query: _resultQuery,
                                  maxLines: 1,
                                ),
                                subtitle: Text(tr(context, '打开会话')),
                                onTap: () => widget.onSelected(
                                  MessageSearchSelection(conversation.id),
                                ),
                              );
                            }
                            if (_entries.isEmpty) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 24,
                                ),
                                child: Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        tr(
                                          context,
                                          _loading
                                              ? '搜索中…'
                                              : _error ??
                                                    (hasQuery
                                                        ? '没有找到相关消息'
                                                        : '搜索结果会显示在这里'),
                                        ),
                                      ),
                                      if (_error != null)
                                        TextButton(
                                          onPressed: () =>
                                              setState(() => _resultKey = null),
                                          child: Text(tr(context, '重试')),
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            }
                            if (index == _names.length + _entries.length + 1) {
                              return TextButton(
                                onPressed: _loading ? null : _loadMore,
                                child: Text(
                                  tr(context, _loading ? '加载中…' : '加载更多'),
                                ),
                              );
                            }
                            final entry = _entries[index - _names.length - 1];
                            final item = entry.item;
                            return ListTile(
                              key: ValueKey('search-result-${item.id}'),
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 4,
                              ),
                              leading: _sidebar
                                  ? null
                                  : Icon(switch (item.kind) {
                                      MessageKind.text => Icons.notes_rounded,
                                      MessageKind.image => Icons.image_outlined,
                                      MessageKind.video => Icons.movie_outlined,
                                      _ => Icons.insert_drive_file_outlined,
                                    }),
                              title: HighlightedText(
                                searchExcerpt(
                                  item.isFile ? item.name : item.text,
                                  _resultQuery,
                                ),
                                query: _resultQuery,
                                maxLines: _sidebar ? 2 : 3,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              subtitle: Text(
                                '${_conversationNames[item.conversationId] ?? tr(context, '同步中的会话')} · '
                                '${item.createdAt.toLocal().toString().substring(0, 16)}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => widget.onSelected(
                                MessageSearchSelection(
                                  item.conversationId,
                                  entry,
                                  _resultQuery,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
