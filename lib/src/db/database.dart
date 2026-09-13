import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static Future<AppDatabase> open({
    required String path,
    required String schemaSqlPath,
  }) async {
    final dir = Directory(File(path).parent.path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final db = sqlite3.open(path);
    final schema = await File(schemaSqlPath).readAsString();
    db.execute(schema);
    return AppDatabase._(db);
  }

  void close() => db.dispose();
}
