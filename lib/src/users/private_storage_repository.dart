import '../db/database.dart';

/// XEP-0049 private XML storage. Each stored blob is the raw serialized
/// child element of `<query xmlns="jabber:iq:private">`, keyed by that
/// child's `{namespace}localName`. Backs XEP-0048 bookmarks.
class PrivateStorageRepository {
  PrivateStorageRepository(this._db);

  final AppDatabase _db;

  String? find(String userId, String elementKey) {
    final rs = _db.db.select(
      'SELECT xml FROM private_storage WHERE user_id = ? AND element_key = ?',
      [userId, elementKey],
    );
    if (rs.isEmpty) return null;
    return rs.first['xml'] as String;
  }

  void upsert(String userId, String elementKey, String xml) {
    _db.db.execute(
      '''
      INSERT INTO private_storage (user_id, element_key, xml, updated_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(user_id, element_key) DO UPDATE SET
        xml = excluded.xml,
        updated_at = excluded.updated_at
      ''',
      [userId, elementKey, xml, DateTime.now().toUtc().toIso8601String()],
    );
  }
}
