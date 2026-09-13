import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../util/ids.dart';
import 'user_model.dart';

class UserRepository {
  UserRepository(this._db, this._ids);

  final AppDatabase _db;
  final ObjectIdGen _ids;

  static String _hash(String password, String saltHex) {
    return sha256.convert(utf8.encode('$saltHex$password')).toString();
  }

  static String _newSalt() {
    final r = Random.secure();
    final buf = StringBuffer();
    for (var i = 0; i < 8; i++) {
      buf.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  User _row(Row r) => User(
    id: r['id'] as String,
    loginEmail: r['login_email'] as String,
    firstName: r['first_name'] as String?,
    lastName: r['last_name'] as String?,
    nickName: r['nick_name'] as String?,
    title: r['title'] as String?,
    jobTitle: r['job_title'] as String?,
    companyId: r['company_id'] as String?,
    language: (r['language'] as String?) ?? 'en',
    isActive: (r['is_active'] as int) == 1,
    isInitialized: (r['is_initialized'] as int) == 1,
    emailVerified: (r['email_verified'] as int? ?? 1) == 1,
    createdAt: DateTime.parse(r['created_at'] as String),
    updatedAt: DateTime.parse(r['updated_at'] as String),
  );

  User? findById(String id) {
    final rs = _db.db.select('SELECT * FROM users WHERE id = ?', [id]);
    return rs.isEmpty ? null : _row(rs.first);
  }

  User? findByEmail(String email) {
    final rs = _db.db.select(
      'SELECT * FROM users WHERE login_email = ? COLLATE NOCASE',
      [email],
    );
    return rs.isEmpty ? null : _row(rs.first);
  }

  bool verifyPassword(User u, String password) {
    final rs = _db.db.select(
      'SELECT password_hash, password_salt FROM users WHERE id = ?',
      [u.id],
    );
    if (rs.isEmpty) return false;
    final row = rs.first;
    return _hash(password, row['password_salt'] as String) ==
        row['password_hash'] as String;
  }

  User create({
    required String loginEmail,
    required String password,
    String? firstName,
    String? lastName,
    bool emailVerified = true,
  }) {
    final now = DateTime.now().toUtc();
    final salt = _newSalt();
    final id = _ids.next();
    _db.db.execute(
      '''
      INSERT INTO users
        (id, login_email, password_hash, password_salt,
         first_name, last_name, email_verified, verified_at,
         created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        id,
        loginEmail,
        _hash(password, salt),
        salt,
        firstName,
        lastName,
        emailVerified ? 1 : 0,
        emailVerified ? now.toIso8601String() : null,
        now.toIso8601String(),
        now.toIso8601String(),
      ],
    );
    return findById(id)!;
  }

  /// Marks the account's email as verified (idempotent).
  User markEmailVerified(String id) {
    final now = DateTime.now().toUtc();
    _db.db.execute(
      'UPDATE users SET email_verified = 1, verified_at = ?, updated_at = ? '
      'WHERE id = ?',
      [now.toIso8601String(), now.toIso8601String(), id],
    );
    return findById(id)!;
  }

  User update(
    String id, {
    String? firstName,
    String? lastName,
    String? nickName,
    String? title,
    String? jobTitle,
    String? language,
  }) {
    final existing = findById(id);
    if (existing == null) {
      throw StateError('User $id not found');
    }
    _db.db.execute(
      '''
      UPDATE users SET
        first_name = COALESCE(?, first_name),
        last_name  = COALESCE(?, last_name),
        nick_name  = COALESCE(?, nick_name),
        title      = COALESCE(?, title),
        job_title  = COALESCE(?, job_title),
        language   = COALESCE(?, language),
        updated_at = ?
      WHERE id = ?
      ''',
      [
        firstName,
        lastName,
        nickName,
        title,
        jobTitle,
        language,
        DateTime.now().toUtc().toIso8601String(),
        id,
      ],
    );
    return findById(id)!;
  }

  void setPassword(String userId, String newPassword) {
    final salt = _newSalt();
    _db.db.execute(
      'UPDATE users SET password_hash = ?, password_salt = ?, updated_at = ? WHERE id = ?',
      [
        _hash(newPassword, salt),
        salt,
        DateTime.now().toUtc().toIso8601String(),
        userId,
      ],
    );
  }

  List<User> search(String q, {int offset = 0, int limit = 50}) {
    final pattern = '%${q.replaceAll('%', '\\%').replaceAll('_', '\\_')}%';
    final rs = _db.db.select(
      '''
      SELECT * FROM users
      WHERE (? = ''
             OR login_email LIKE ? ESCAPE '\\' COLLATE NOCASE
             OR first_name  LIKE ? ESCAPE '\\' COLLATE NOCASE
             OR last_name   LIKE ? ESCAPE '\\' COLLATE NOCASE
             OR nick_name   LIKE ? ESCAPE '\\' COLLATE NOCASE)
      ORDER BY last_name, first_name, login_email
      LIMIT ? OFFSET ?
      ''',
      [q, pattern, pattern, pattern, pattern, limit, offset],
    );
    return rs.map(_row).toList();
  }

  int countSearch(String q) {
    final pattern = '%${q.replaceAll('%', '\\%').replaceAll('_', '\\_')}%';
    final rs = _db.db.select(
      '''
      SELECT COUNT(*) AS n FROM users
      WHERE (? = ''
             OR login_email LIKE ? ESCAPE '\\' COLLATE NOCASE
             OR first_name  LIKE ? ESCAPE '\\' COLLATE NOCASE
             OR last_name   LIKE ? ESCAPE '\\' COLLATE NOCASE
             OR nick_name   LIKE ? ESCAPE '\\' COLLATE NOCASE)
      ''',
      [q, pattern, pattern, pattern, pattern],
    );
    return rs.first['n'] as int;
  }
}
