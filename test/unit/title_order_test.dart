import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/platform/title_order.dart';

void main() {
  test(
    'title labels use the first non-empty line and do not split Unicode',
    () {
      expect(TitleOrder.label(' \n\n  北京笔记\n第二行'), '北京笔记');
      expect(TitleOrder.label('  file.zip '), 'file.zip');
      expect(TitleOrder.label('😀' * 300), '😀' * 256);
      expect(TitleOrder.label(' \n  '), '');
    },
  );

  test(
    'filtering and repeated sorting reuse keys and only compute new titles',
    () async {
      final calls = <List<String>>[];
      final order = TitleOrder(
        keyLoader: (titles) async {
          calls.add(List.of(titles));
          return [
            for (final title in titles) Uint8List.fromList(title.codeUnits),
          ];
        },
      );
      expect(await order.ranks(['b', 'a', 'a']), {'a': 0, 'b': 1});
      expect(await order.ranks(['b']), {'b': 0});
      expect(await order.ranks(['b', 'c', 'a']), {'a': 0, 'b': 1, 'c': 2});
      expect(calls, [
        ['b', 'a'],
        ['c'],
      ]);
    },
  );

  test(
    'an unsuccessful request can retry without poisoning later sort requests',
    () async {
      var fail = true;
      final order = TitleOrder(
        keyLoader: (titles) async {
          if (fail) throw StateError('Injected collation failure');
          return [
            for (final title in titles) Uint8List.fromList(title.codeUnits),
          ];
        },
      );
      await expectLater(order.ranks(['b', 'a']), throwsStateError);
      fail = false;
      expect(await order.ranks(['b', 'a']), {'a': 0, 'b': 1});
    },
  );

  test('Windows title order uses Chinese pinyin and Latin letters', () async {
    final ranks = await TitleOrder().ranks([
      '张三',
      '上海',
      '北京',
      '阿尔法',
      'zebra',
      'apple',
    ]);
    expect(ranks['阿尔法'], lessThan(ranks['北京']!));
    expect(ranks['北京'], lessThan(ranks['上海']!));
    expect(ranks['上海'], lessThan(ranks['张三']!));
    expect(ranks['apple'], lessThan(ranks['zebra']!));
  }, skip: !Platform.isWindows);
}
