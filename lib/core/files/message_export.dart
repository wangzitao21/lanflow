import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'file_utils.dart';

Future<File> exportMessages(
  List<Map<String, dynamic>> records,
  Directory temporary,
) async {
  final output = p.join(temporary.path, 'LanFlow-messages.zip');
  await Isolate.run(() async {
    final encoder = ZipFileEncoder()
      ..create(output, level: ZipFileEncoder.store);
    final metadata = File(p.join(temporary.path, 'messages.json'));
    final text = File(p.join(temporary.path, 'messages.txt'));
    final jsonSink = metadata.openWrite();
    final textSink = text.openWrite();
    try {
      jsonSink.write('[');
      for (var i = 0; i < records.length; i++) {
        final record = Map<String, dynamic>.from(records[i]);
        final source = record.remove('sourcePath') as String?;
        if (source != null) {
          final relative =
              'attachments/${record['id']}/${safeFileName(record['name'] as String)}';
          await encoder.addFile(File(source), relative, ZipFileEncoder.store);
          record['attachment'] = relative;
        }
        if (i > 0) jsonSink.write(',');
        jsonSink.write(jsonEncode(record));
        textSink.writeln('[${record['createdAt']}] ${record['originName']}');
        textSink.writeln(
          record['kind'] == 'text' ? record['text'] : record['attachment'],
        );
        textSink.writeln();
      }
      jsonSink.write(']');
      await jsonSink.close();
      await textSink.close();
      await encoder.addFile(metadata, 'messages.json');
      await encoder.addFile(text, 'messages.txt');
    } finally {
      await jsonSink.close();
      await textSink.close();
      await encoder.close();
    }
  });
  return File(output);
}
