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
    _migrate(db);
    return AppDatabase._(db);
  }

  /// Additive, idempotent column migrations for DBs created before a
  /// schema field existed.
  static void _migrate(Database db) {
    final cols = db
        .select('PRAGMA table_info(bubble_messages)')
        .map((r) => r['name'] as String)
        .toSet();
    if (!cols.contains('thread')) {
      db.execute('ALTER TABLE bubble_messages ADD COLUMN thread TEXT');
    }
    if (!cols.contains('subject')) {
      db.execute('ALTER TABLE bubble_messages ADD COLUMN subject TEXT');
    }
  }

  void close() => db.dispose();
}
