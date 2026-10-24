import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/core/storage/local_store.dart';

class _SearchStore extends InboxStore {
  _SearchStore(super.directory);
  final queries = <Map<String, dynamic>>[];
  final responses = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> searchMessages(Map<String, dynamic> query) {
    queries.add(query);
    final result = Completer<Map<String, dynamic>>();
    responses.add(result);
    return result.future;
  }
}

void main() {
  late _SearchStore store;
  late LanController lan;
  late InboxController inbox;
  setUp(() {
    final root = Directory(
      '${Directory.systemTemp.path}/lanflow-search-queue-unit',
    );
    store = _SearchStore(root);
    lan = LanController(store: LocalStore(root), receiveDirectory: root);
    inbox = InboxController(lan: lan, store: store, automaticSync: false);
  });
  tearDown(() {
    inbox.dispose();
    lan.dispose();
  });
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test(
    'only the active and newest queued query run for a search session',
    () async {
      final session = Object();
      final first = inbox.searchMessages({'query': 'a'}, requestGroup: session);
      final skipped = inbox.searchMessages({
        'query': 'ab',
      }, requestGroup: session);
      final rejected = expectLater(
        skipped,
        throwsA(isA<SearchSupersededException>()),
      );
      final latest = inbox.searchMessages({
        'query': 'abc',
      }, requestGroup: session);
      expect(store.queries.map((q) => q['query']), ['a']);
      store.responses.first.complete({'query': 'a'});
      expect(await first, {'query': 'a'});
      await settle();
      expect(store.queries.map((q) => q['query']), ['a', 'abc']);
      store.responses.last.complete({'query': 'abc'});
      expect(await latest, {'query': 'abc'});
      await rejected;
      await settle();
    },
  );

  test(
    'different sessions and ungrouped queries retain their own results',
    () async {
      final first = inbox.searchMessages({
        'query': 'one',
      }, requestGroup: Object());
      final second = inbox.searchMessages({
        'query': 'two',
      }, requestGroup: Object());
      final third = inbox.searchMessages({'query': 'three'});
      store.responses.first.complete({'result': 1});
      expect(await first, {'result': 1});
      await settle();
      expect(store.queries.last['query'], 'two');
      store.responses.last.complete({'result': 2});
      expect(await second, {'result': 2});
      await settle();
      expect(store.queries.last['query'], 'three');
      store.responses.last.complete({'result': 3});
      expect(await third, {'result': 3});
      await settle();
    },
  );

  test(
    'identical searches share work but a changed data revision is queried again',
    () async {
      final session = Object();
      final first = inbox.searchMessages({
        'query': 'same',
      }, requestGroup: session);
      final repeated = inbox.searchMessages({
        'query': 'same',
      }, requestGroup: session);
      expect(identical(first, repeated), isTrue);
      store.revision++;
      final refreshed = inbox.searchMessages({
        'query': 'same',
      }, requestGroup: session);
      store.responses.first.complete({'result': 'before'});
      expect(await first, {'result': 'before'});
      await settle();
      expect(store.queries.length, 2);
      store.responses.last.complete({'result': 'after'});
      expect(await refreshed, {'result': 'after'});
      await settle();
    },
  );

  test('closing one search panel drops only its pending query', () async {
    final closed = Object();
    final active = inbox.searchMessages({'query': 'active'});
    final dropped = inbox.searchMessages({
      'query': 'closed',
    }, requestGroup: closed);
    final rejected = expectLater(
      dropped,
      throwsA(isA<SearchSupersededException>()),
    );
    final retained = inbox.searchMessages({
      'query': 'retained',
    }, requestGroup: Object());
    inbox.cancelMessageSearches(closed);
    store.responses.first.complete({'result': 'active'});
    await active;
    await settle();
    expect(store.queries.map((query) => query['query']), [
      'active',
      'retained',
    ]);
    store.responses.last.complete({'result': 'retained'});
    expect(await retained, {'result': 'retained'});
    await rejected;
    await settle();
  });

  test(
    'a failed search does not prevent the latest queued search from running',
    () async {
      final session = Object();
      final first = inbox.searchMessages({
        'query': 'first',
      }, requestGroup: session);
      final rejected = expectLater(first, throwsA(isA<StateError>()));
      final next = inbox.searchMessages({
        'query': 'next',
      }, requestGroup: session);
      store.responses.first.completeError(
        StateError('temporary search failure'),
      );
      await rejected;
      await settle();
      expect(store.queries.last['query'], 'next');
      store.responses.last.complete({'result': 'next'});
      expect(await next, {'result': 'next'});
      await settle();
    },
  );
}
