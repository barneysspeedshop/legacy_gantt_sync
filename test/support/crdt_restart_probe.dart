import 'dart:io';

import 'package:legacy_gantt_sync/server/services/crdt_service.dart';

Future<void> main() async {
  await CrdtService().init();
  stdout.writeln('CRDT_RESTART_READY');
  exit(0);
}
