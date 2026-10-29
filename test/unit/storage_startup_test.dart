import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/storage/storage_location.dart';
import 'package:lanflow/core/storage/storage_startup.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary, bootstrap, documents, original;
  late Map<String, String> environment;

  Future<void> data(Directory root) async {
    await Directory(
      p.join(root.path, 'system', 'device'),
    ).create(recursive: true);
    await File(
      p.join(root.path, 'system', 'messages.sqlite3'),
    ).writeAsString('saved messages');
    await File(
      p.join(root.path, 'system', 'device', 'identity.json'),
    ).writeAsString('saved identity');
  }

  Future<StorageStartup> startup({Map<String, String>? env}) =>
      StorageStartup.resolve(
        windows: true,
        environment: env ?? environment,
        resolveDocuments: () async => documents,
      );

  final locatorNames = [
    'system/storage-location.json',
    'system/storage-location.json.backup',
    'storage-location.json',
    'storage-location.json.backup',
  ];
  File locator(String name) =>
      File(p.joinAll([bootstrap.path, ...name.split('/')]));

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'lanflow-storage-startup-',
    );
    final appData = p.join(temporary.path, 'AppData');
    bootstrap = Directory(p.join(appData, 'dev.lanflow', 'lanflow'));
    documents = Directory(p.join(temporary.path, 'Documents'));
    original = Directory(p.join(documents.path, 'LanFlow'));
    environment = {'APPDATA': appData};
  });
  tearDown(() => temporary.delete(recursive: true));

  test(
    'normal startup remembers an explicit data root after the environment disappears',
    () async {
      await data(original);
      final first = await startup(
        env: {...environment, 'LANFLOW_DATA_DIR': original.path},
      );
      expect(first.location.bootstrap.path, bootstrap.path);
      expect(first.root.path, original.path);
      for (var restart = 0; restart < 3; restart++) {
        final next = await StorageStartup.resolve(
          windows: true,
          environment: environment,
          resolveDocuments: () =>
              throw StateError('Saved paths must not depend on Documents'),
        );
        expect(next.root.path, original.path);
      }
      for (final name in locatorNames) {
        expect(
          jsonDecode(await locator(name).readAsString())['path'],
          original.path,
        );
      }
    },
  );

  test(
    'a fresh installation pins a fixed user directory before opening data',
    () async {
      final first = await startup();
      expect(first.root.path, bootstrap.path);
      expect(
        jsonDecode(
          await locator(locatorNames.first).readAsString(),
        )['initialized'],
        false,
      );
      await data(bootstrap);
      expect((await startup()).root.path, bootstrap.path);
      expect(
        jsonDecode(
          await locator(locatorNames.first).readAsString(),
        )['initialized'],
        true,
      );
    },
  );

  test(
    'unrecorded Documents data is recovered before creating a default database',
    () async {
      await data(original);
      expect((await startup()).root.path, original.path);
      expect(
        await File(
          p.join(bootstrap.path, 'system', 'messages.sqlite3'),
        ).exists(),
        false,
      );
      expect(
        await File(
          p.join(original.path, 'system', 'messages.sqlite3'),
        ).readAsString(),
        'saved messages',
      );
    },
  );

  test(
    'two existing stores require a choice instead of silently hiding one',
    () async {
      await data(original);
      await data(bootstrap);
      await expectLater(startup(), throwsA(isA<FileSystemException>()));
      expect(await locator(locatorNames.first).exists(), false);
      expect(await StorageLocation.containsData(original), true);
      expect(await StorageLocation.containsData(bootstrap), true);
    },
  );

  test(
    'an alternate launch path cannot replace the remembered store',
    () async {
      await data(original);
      await startup();
      final unexpected = Directory(p.join(temporary.path, 'unexpected'));
      await expectLater(
        startup(env: {...environment, 'LANFLOW_DATA_DIR': unexpected.path}),
        throwsA(isA<FileSystemException>()),
      );
      expect(await unexpected.exists(), false);
      expect((await startup()).root.path, original.path);
    },
  );

  test(
    'missing selected disk never falls back to an older valid backup',
    () async {
      await data(original);
      await startup();
      await data(bootstrap);
      await locator(
        locatorNames[1],
      ).writeAsString(jsonEncode({'path': bootstrap.path}));
      final away = await original.rename('${original.path}-disconnected');
      await expectLater(startup(), throwsA(isA<FileSystemException>()));
      expect(await original.exists(), false);
      expect(await StorageLocation.containsData(away), true);
    },
  );

  test(
    'an existing but emptied data directory cannot create a new identity',
    () async {
      await data(original);
      await startup();
      await Directory(p.join(original.path, 'system')).delete(recursive: true);
      await expectLater(startup(), throwsA(isA<FileSystemException>()));
      expect(await Directory(p.join(original.path, 'system')).exists(), false);
    },
  );

  test(
    'backup recovery repairs the primary and survives loss of system configuration',
    () async {
      await data(original);
      await startup();
      await locator(locatorNames.first).writeAsString('corrupt');
      expect((await startup()).root.path, original.path);
      expect(
        jsonDecode(await locator(locatorNames.first).readAsString())['path'],
        original.path,
      );
      await Directory(p.join(bootstrap.path, 'system')).delete(recursive: true);
      expect((await startup()).root.path, original.path);
      expect((await startup()).root.path, original.path);
    },
  );

  test(
    'unreadable location records never initialize a replacement store',
    () async {
      await data(original);
      await startup();
      for (final name in locatorNames) {
        await locator(name).writeAsString('corrupt');
      }
      await expectLater(startup(), throwsFormatException);
      expect(
        await File(
          p.join(bootstrap.path, 'system', 'messages.sqlite3'),
        ).exists(),
        false,
      );
    },
  );

  test(
    'interrupted first location write is not treated as a fresh install',
    () async {
      final pending = locator('system/storage-location.json.pending');
      await pending.parent.create(recursive: true);
      await pending.writeAsString(jsonEncode({'path': original.path}));
      await expectLater(startup(), throwsA(isA<FileSystemException>()));
      expect(await locator(locatorNames.first).exists(), false);
    },
  );

  test(
    'a directory at the location-file path cannot be silently ignored',
    () async {
      await Directory(locator(locatorNames.first).path).create(recursive: true);
      await expectLater(startup(), throwsA(isA<FileSystemException>()));
    },
  );

  test('partial legacy data is preserved and never initialized over', () async {
    final db = File(p.join(original.path, 'system', 'messages.sqlite3'));
    await db.parent.create(recursive: true);
    await db.writeAsString('preserved database');
    await expectLater(startup(), throwsA(isA<FileSystemException>()));
    expect(await db.readAsString(), 'preserved database');
    expect(await bootstrap.exists(), false);
  });

  test('relative and empty environment paths are rejected', () async {
    for (final invalid in ['', 'relative-data']) {
      await expectLater(
        startup(env: {...environment, 'LANFLOW_DATA_DIR': invalid}),
        throwsFormatException,
      );
    }
    expect(await bootstrap.exists(), false);
  });

  test(
    'explicitly isolated probes do not change the normal storage location',
    () async {
      await data(original);
      await startup();
      final previous = await locator(locatorNames.first).readAsString();
      final isolated = Directory(p.join(temporary.path, 'probe'));
      final probe = await startup(
        env: {
          ...environment,
          'LANFLOW_DATA_DIR': isolated.path,
          'LANFLOW_ISOLATED_STORAGE': '1',
        },
      );
      expect(probe.root.path, isolated.path);
      expect(probe.location.bootstrap.path, isolated.path);
      expect(await locator(locatorNames.first).readAsString(), previous);
      expect((await startup()).root.path, original.path);
    },
  );
}
