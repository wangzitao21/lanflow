import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/core/storage/storage_location.dart';
import 'package:lanflow/runtime.dart';
import 'package:lanflow/ui/chat/home_page.dart';
import 'package:path/path.dart' as p;

TextEditingController? _editor() {
  TextEditingController? found;
  void visit(Element element) {
    final widget = element.widget;
    if (widget is TextField &&
        widget.key == const ValueKey('inbox-composer') &&
        widget.enabled == true) {
      found = widget.controller;
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

HomePage? _home() {
  HomePage? found;
  void visit(Element element) {
    if (element.widget is HomePage) found = element.widget as HomePage;
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final value = Platform.environment['LANFLOW_DATA_DIR'];
  if (value == null ||
      !p.isAbsolute(value) ||
      Platform.environment['LANFLOW_START_HIDDEN'] != '1') {
    stderr.writeln(
      'The quit probe requires an isolated data directory and hidden startup.',
    );
    exit(2);
  }
  final root = Directory(value);
  final report = File(p.join(root.path, 'quit-probe.json'));
  try {
    final session = await RuntimeSession.open(
      root,
      enableDiscovery: false,
      preferredPort: 0,
      bindAddress: InternetAddress.loopbackIPv4,
    );
    runApp(LanFlowHost(session: session, location: StorageLocation(root)));
    await session.start(acceptShares: false);
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    TextEditingController? editor;
    while ((editor = _editor()) == null) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('The live editor did not become ready');
      }
      WidgetsBinding.instance.scheduleFrame();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // Establish an empty, durable baseline. Changes below deliberately use the
    // same debounced paths as ordinary typing and device-setting updates.
    await session.inbox.store.flush();
    await session.lan.retrySave();
    final peerId = 'a' * 32;
    const draft = 'quit probe: preserve the final unsent edit';
    const name = 'quit-probe-pending-name';
    final mode = Platform.environment['LANFLOW_QUIT_PROBE_MODE'] ?? 'normal';
    final blockedWrite = Directory(
      p.join(root.path, 'system', 'device', 'state.pending.json'),
    );
    if (mode == 'failure') await blockedWrite.create();
    final details = <String, dynamic>{
      'pid': pid,
      'editorReady': true,
      'expectedDraft': draft,
      'expectedName': name,
      'peerId': peerId,
      'mode': mode,
    };
    report.writeAsStringSync(jsonEncode(details), flush: true);
    session.lan.peers[peerId] = Peer(
      id: peerId,
      name: 'isolated synthetic peer',
      platform: 'windows',
      address: '127.0.0.1',
      port: 9,
      fingerprint: 'a' * 64,
      inboxVersion: 0,
      online: false,
    );
    session.lan.sessions[peerId] = PeerSession(
      receiveToken: 'probe-receive-token',
      sendToken: 'probe-send-token',
    );
    session.lan.updateSettings(deviceName: name);
    editor!.text = draft;
    try {
      await const MethodChannel('lanflow/desktop').invokeMethod<void>('quit');
      if (mode == 'failure') {
        throw StateError('The failed save was allowed to quit');
      }
    } on PlatformException catch (error) {
      if (mode != 'failure' || error.code != 'SAVE_FAILED') rethrow;
      final recovered = _home();
      final recoveredEditor = _editor();
      details['failureRetainedDraft'] =
          recovered?.inbox.store.draft == draft &&
          recoveredEditor?.text == draft;
      details['failureRetainedBinding'] =
          recovered?.controller.sessions.containsKey(peerId) == true;
      details['failureEditable'] =
          recoveredEditor != null && recovered?.inbox.ready == true;
      details['recoveredSession'] =
          recovered != null && !identical(recovered.inbox, session.inbox);
      if (details.entries.any(
        (entry) => entry.key.startsWith('failure') && entry.value != true,
      )) {
        throw StateError('Failed exit did not preserve an editable session');
      }
      await blockedWrite.delete();
      const continued = '$draft (continued after rejected exit)';
      recoveredEditor!.text = continued;
      details['expectedDraft'] = continued;
      report.writeAsStringSync(jsonEncode(details), flush: true);
      await const MethodChannel('lanflow/desktop').invokeMethod<void>('quit');
    }
  } on Object catch (error, stack) {
    await root.create(recursive: true);
    await report.writeAsString(
      jsonEncode({
        'pid': pid,
        'error': error.toString(),
        'stack': stack.toString(),
      }),
      flush: true,
    );
    exit(3);
  }
}
