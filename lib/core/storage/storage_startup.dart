import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'storage_location.dart';

class StorageStartup {
  StorageStartup(this.location, this.root);

  final StorageLocation location;
  final Directory root;

  static Future<StorageStartup> resolve({
    Map<String, String>? environment,
    bool? windows,
    Future<Directory> Function()? resolveBootstrap,
    Future<Directory> Function()? resolveDocuments,
  }) async {
    final env = environment ?? Platform.environment;
    final requested = env['LANFLOW_DATA_DIR'];
    if (requested != null && (requested.isEmpty || !p.isAbsolute(requested))) {
      throw const FormatException('存储位置必须是完整的绝对路径');
    }
    final isolated = env['LANFLOW_ISOLATED_STORAGE'] == '1';
    if (isolated && requested == null) {
      throw const FormatException('隔离运行必须指定存储位置');
    }
    final isWindows = windows ?? Platform.isWindows;
    final Directory bootstrap;
    if (resolveBootstrap != null) {
      bootstrap = await resolveBootstrap();
    } else if (isolated) {
      bootstrap = Directory(requested!);
    } else if (isWindows) {
      final appData = env['APPDATA'];
      if (appData == null || !p.isAbsolute(appData)) {
        throw const FileSystemException('无法确定固定的配置目录，请检查用户配置');
      }
      // This identifier must not depend on executable metadata, version,
      // installation directory, or the shell's working directory.
      bootstrap = Directory(p.join(appData, 'dev.lanflow', 'lanflow'));
    } else {
      bootstrap = await getApplicationSupportDirectory();
    }
    final location = StorageLocation(bootstrap);
    final root = await location.resolve(
      initialRoot: requested != null && !isolated && resolveBootstrap == null
          ? Directory(p.normalize(requested))
          : null,
      recoveryRoots: isWindows && !isolated && resolveBootstrap == null
          ? () async => [
              Directory(
                p.join(
                  (await (resolveDocuments ??
                          getApplicationDocumentsDirectory)())
                      .path,
                  'LanFlow',
                ),
              ),
            ]
          : null,
    );
    return StorageStartup(location, root);
  }
}
