import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/models.dart';

import 'widget_harness.dart';

class FavoriteUiInbox extends WidgetInbox {
  FavoriteUiInbox({required super.lan, required super.store});
  final saved = <FavoriteEntry>[];
  final deletedFavorites = <String, FavoriteEntry>{};
  final attachmentFiles = <String, File>{};
  int deleteCalls = 0;
  int fileExportRequests = 0;
  bool failPreferences = false;

  @override
  Future<void> setFavoritePreferences(FavoritePreferences value) async {
    if (failPreferences) throw const FileSystemException('磁盘写入失败');
    store.favoritePreferences = value;
    notifyListeners();
  }

  @override
  Future<void> setFavoritesPinned(Iterable<String> ids, bool pinned) async {
    final pins = {...favoritePreferences.pinned};
    for (final id in ids) {
      if (pinned) {
        pins[id] = DateTime.now().millisecondsSinceEpoch;
      } else {
        pins.remove(id);
      }
    }
    await setFavoritePreferences(favoritePreferences.copyWith(pinned: pins));
  }

  @override
  List<FavoriteEntry> get favoriteEntries => saved;

  void changed() {
    saved.sort((a, b) {
      final order = b.savedAt.compareTo(a.savedAt);
      return order != 0 ? order : b.id.compareTo(a.id);
    });
    store.favoritesRevision++;
    notifyListeners();
  }

  FavoriteEntry capture(InboxItem original, {DateTime? savedAt}) {
    final id = randomToken(18);
    final entry = FavoriteEntry.fromJson({
      'snapshotId': id,
      'id': original.id,
      'savedAt': (savedAt ?? DateTime.now().toUtc()).toIso8601String(),
      'revision': 1,
      'item': {...original.toJson(), 'id': id},
    });
    saved.add(entry);
    store.favorites.add(original.id);
    changed();
    return entry;
  }

  @override
  Future<void> deleteFavorites(Iterable<String> ids) async {
    deleteCalls++;
    final selected = ids.toSet();
    final removing = saved
        .where((entry) => selected.contains(entry.id))
        .toList();
    for (final entry in removing) {
      deletedFavorites[entry.id] = entry;
      store.favorites.remove(entry.originalMessageId);
      if (linkFavoriteDeletion) {
        final original = store.find(entry.originalMessageId);
        if (original != null) await super.deleteItem(original.item);
      }
    }
    saved.removeWhere((entry) => selected.contains(entry.id));
    changed();
  }

  @override
  Future<void> restoreFavorites(Iterable<String> ids) async {
    for (final id in ids) {
      final entry = deletedFavorites.remove(id);
      if (entry != null) {
        saved.add(entry);
        store.favorites.add(entry.originalMessageId);
      }
    }
    changed();
  }

  @override
  Future<File> favoriteFileForExport(FavoriteEntry entry) async {
    fileExportRequests++;
    final file = attachmentFiles[entry.id];
    if (file == null || !await file.exists()) {
      throw const FileSystemException('文件不存在');
    }
    return file;
  }

  @override
  Future<File> favoriteFileForOpening(FavoriteEntry entry) async {
    final source = await favoriteFileForExport(entry);
    final folder = await Directory(
      '${store.directory.path}/preview-${entry.id}',
    ).create();
    return source.copy('${folder.path}/${entry.item.name}');
  }

  @override
  Future<bool> favoriteAvailable(FavoriteEntry entry) async =>
      !entry.item.isFile || await attachmentFiles[entry.id]?.exists() == true;
}

Future<FavoriteUiInbox> installFavoriteUiInbox(
  WidgetTester tester,
  WidgetTestHarness harness,
) async {
  late FavoriteUiInbox inbox;
  await tester.runAsync(() async {
    await harness.inbox.close();
    harness.inbox.dispose();
    inbox = FavoriteUiInbox(
      lan: harness.lan,
      store: InboxStore(harness.directory),
    );
    harness.inbox = inbox;
    await inbox.start();
  });
  return inbox;
}

Future<File> favoriteImageFixture(
  Directory directory,
  String name,
  int width,
  int height,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFFB9D9CC),
  );
  canvas.drawCircle(
    Offset(width * .65, height * .28),
    width * .24,
    Paint()..color = const Color(0xFFF4E2AB),
  );
  final shape = Path()
    ..moveTo(0, height * .8)
    ..lineTo(width * .55, height * .46)
    ..lineTo(width.toDouble(), height * .84)
    ..lineTo(width.toDouble(), height.toDouble())
    ..lineTo(0, height.toDouble())
    ..close();
  canvas.drawPath(shape, Paint()..color = const Color(0xFF518A75));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('${directory.path}/$name');
    await file.writeAsBytes(data!.buffer.asUint8List());
    return file;
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<void> settleFavoriteImages(WidgetTester tester) async {
  await tester.pump();
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    final rendered = tester
        .widgetList<RawImage>(find.byType(RawImage))
        .toList();
    if (rendered.isNotEmpty && rendered.every((image) => image.image != null)) {
      break;
    }
  }
  await tester.pumpAndSettle();
}
