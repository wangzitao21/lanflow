import 'dart:convert';
import 'dart:io';

import 'package:lanflow/platform/native_core.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) exit(2);
  final root = arguments.first;
  try {
    final report =
        jsonDecode(await File(p.join(root, 'quit-probe.json')).readAsString())
            as Map;
    if (report['editorReady'] != true) {
      throw StateError('The quit probe did not reach the editor');
    }
    final snapshot =
        await NativeCore.run({'op': 'open_paged', 'root': root}) as Map;
    final statePath = p.join(root, 'system', 'device', 'state.json');
    final state = await File(statePath).exists()
        ? jsonDecode(await File(statePath).readAsString()) as Map
        : <String, dynamic>{};
    final result = {
      'draftSaved':
          (snapshot['drafts'] as Map?)?['lanflow-self-chat'] ==
          report['expectedDraft'],
      'bindingSaved':
          (state['sessions'] as Map?)?.containsKey(report['peerId']) == true,
      'deviceNameSaved': state['name'] == report['expectedName'],
      'editorReady': report['editorReady'],
      if (report['mode'] == 'failure') ...{
        'failureRetainedDraft': report['failureRetainedDraft'],
        'failureRetainedBinding': report['failureRetainedBinding'],
        'failureEditable': report['failureEditable'],
        'recoveredSession': report['recoveredSession'],
      },
    };
    await NativeCore.run({'op': 'close', 'root': root});
    stdout.writeln(jsonEncode(result));
    await File(
      p.join(root, 'quit-verification.json'),
    ).writeAsString(jsonEncode(result), flush: true);
    exit(
      arguments.contains('--expect-saved') &&
              result.values.any((value) => value != true)
          ? 1
          : 0,
    );
  } on Object catch (error) {
    stderr.writeln(error);
    exit(2);
  }
}
