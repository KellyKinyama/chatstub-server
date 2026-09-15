import '../db/database.dart';

/// Stored XEP-0054 vcard-temp text fields for one user. PHOTO is not held
/// here — it is bridged to the avatar store so REST and XMPP stay in sync.
class VcardData {
  VcardData({this.fn, this.nickname, this.email});

  final String? fn;
  final String? nickname;
  final String? email;
}

class VcardRepository {
  VcardRepository(this._db);

  final AppDatabase _db;

  VcardData? find(String userId) {
    final rs = _db.db.select(
      'SELECT fn, nickname, email FROM vcards WHERE user_id = ?',
      [userId],
    );
    if (rs.isEmpty) return null;
    final r = rs.first;
    return VcardData(
      fn: r['fn'] as String?,
      nickname: r['nickname'] as String?,
      email: r['email'] as String?,
    );
  }

  void upsert(String userId, {String? fn, String? nickname, String? email}) {
    _db.db.execute(
      '''
      INSERT INTO vcards (user_id, fn, nickname, email, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(user_id) DO UPDATE SET
        fn = excluded.fn,
        nickname = excluded.nickname,
        email = excluded.email,
        updated_at = excluded.updated_at
      ''',
      [
        userId,
        fn,
        nickname,
        email,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }
}
