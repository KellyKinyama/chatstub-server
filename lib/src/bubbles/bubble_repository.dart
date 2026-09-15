import '../db/database.dart';
import '../util/ids.dart';
import '../xmpp/jid.dart';

class Bubble {
  Bubble({
    required this.id,
    required this.name,
    this.topic,
    required this.ownerId,
    required this.visibility,
    required this.archived,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String? topic;
  final String ownerId;
  final String visibility;
  final bool archived;
  final DateTime createdAt;
  final DateTime updatedAt;

  Jid jid(String domain) => Jid(local: id, domain: domain);
}

class BubbleMember {
  BubbleMember({
    required this.bubbleId,
    required this.userId,
    required this.role,
    required this.status,
    required this.joinedAt,
  });

  final String bubbleId;
  final String userId;
  final String role;
  final String status;
  final DateTime joinedAt;
}

class BubbleMessage {
  BubbleMessage({
    required this.id,
    required this.bubbleId,
    required this.stanzaId,
    required this.from,
    required this.body,
    required this.sentAt,
    this.thread,
    this.subject,
  });

  final String id;
  final String bubbleId;
  final String stanzaId;
  final Jid from;
  final String body;
  final DateTime sentAt;

  /// XEP-0201 thread id — the topic this message belongs to.
  final String? thread;

  /// Topic title, carried on the first message that opens a topic.
  final String? subject;
}

/// XEP-0425 moderation record for a MUC message.
class Moderation {
  Moderation({required this.byJid, this.reason});
  final String byJid;
  final String? reason;
}

class BubbleRepository {
  BubbleRepository(this._db, this._ids);

  final AppDatabase _db;
  final ObjectIdGen _ids;

  Bubble _rowToBubble(Map<String, Object?> r) => Bubble(
    id: r['id'] as String,
    name: r['name'] as String,
    topic: r['topic'] as String?,
    ownerId: r['owner_id'] as String,
    visibility: r['visibility'] as String,
    archived: (r['archived'] as int) == 1,
    createdAt: DateTime.parse(r['created_at'] as String),
    updatedAt: DateTime.parse(r['updated_at'] as String),
  );

  Bubble? findById(String id) {
    final rs = _db.db.select('SELECT * FROM bubbles WHERE id = ?', [id]);
    return rs.isEmpty ? null : _rowToBubble(rs.first);
  }

  Bubble create({
    required String ownerId,
    required String name,
    String? topic,
    String visibility = 'private',
  }) {
    final id = _ids.next();
    final now = DateTime.now().toUtc();
    _db.db.execute(
      '''
      INSERT INTO bubbles
        (id, name, topic, owner_id, visibility, archived, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, 0, ?, ?)
      ''',
      [
        id,
        name,
        topic,
        ownerId,
        visibility,
        now.toIso8601String(),
        now.toIso8601String(),
      ],
    );
    _db.db.execute(
      '''
      INSERT INTO bubble_members (bubble_id, user_id, role, status, joined_at)
      VALUES (?, ?, 'owner', 'accepted', ?)
      ''',
      [id, ownerId, now.toIso8601String()],
    );
    return findById(id)!;
  }

  /// Creates a room with a caller-supplied [id] (the MUC local part) and
  /// the creator as owner. Used for XEP-0045 room creation via presence.
  Bubble createWithId({
    required String id,
    required String ownerId,
    required String name,
    String? topic,
    String visibility = 'public',
  }) {
    final now = DateTime.now().toUtc();
    _db.db.execute(
      '''
      INSERT INTO bubbles
        (id, name, topic, owner_id, visibility, archived, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, 0, ?, ?)
      ''',
      [
        id,
        name,
        topic,
        ownerId,
        visibility,
        now.toIso8601String(),
        now.toIso8601String(),
      ],
    );
    _db.db.execute(
      '''
      INSERT INTO bubble_members (bubble_id, user_id, role, status, joined_at)
      VALUES (?, ?, 'owner', 'accepted', ?)
      ''',
      [id, ownerId, now.toIso8601String()],
    );
    return findById(id)!;
  }

  Bubble update(
    String id, {
    String? name,
    String? topic,
    String? visibility,
    bool? archived,
  }) {
    _db.db.execute(
      '''
      UPDATE bubbles SET
        name       = COALESCE(?, name),
        topic      = COALESCE(?, topic),
        visibility = COALESCE(?, visibility),
        archived   = COALESCE(?, archived),
        updated_at = ?
      WHERE id = ?
      ''',
      [
        name,
        topic,
        visibility,
        archived == null ? null : (archived ? 1 : 0),
        DateTime.now().toUtc().toIso8601String(),
        id,
      ],
    );
    return findById(id)!;
  }

  void delete(String id) {
    _db.db.execute('DELETE FROM bubbles WHERE id = ?', [id]);
  }

  /// All bubbles the user is a member of (accepted OR invited).
  List<Bubble> listForUser(String userId, {int offset = 0, int limit = 100}) {
    final rs = _db.db.select(
      '''
      SELECT b.* FROM bubbles b
      JOIN bubble_members m ON m.bubble_id = b.id
      WHERE m.user_id = ? AND m.status IN ('accepted','invited')
      ORDER BY b.updated_at DESC
      LIMIT ? OFFSET ?
      ''',
      [userId, limit, offset],
    );
    return rs.map(_rowToBubble).toList();
  }

  List<Bubble> listInvitedFor(String userId) {
    final rs = _db.db.select(
      '''
      SELECT b.* FROM bubbles b
      JOIN bubble_members m ON m.bubble_id = b.id
      WHERE m.user_id = ? AND m.status = 'invited'
      ORDER BY b.updated_at DESC
      ''',
      [userId],
    );
    return rs.map(_rowToBubble).toList();
  }

  List<BubbleMember> membersOf(String bubbleId) {
    final rs = _db.db.select(
      '''
      SELECT * FROM bubble_members WHERE bubble_id = ?
      ORDER BY role DESC, joined_at ASC
      ''',
      [bubbleId],
    );
    return rs
        .map(
          (r) => BubbleMember(
            bubbleId: r['bubble_id'] as String,
            userId: r['user_id'] as String,
            role: r['role'] as String,
            status: r['status'] as String,
            joinedAt: DateTime.parse(r['joined_at'] as String),
          ),
        )
        .toList();
  }

  /// Convenience: accepted member ids only. Used to fan out server-
  /// synthesized MUC stanzas (e.g. XEP-0424 retract).
  List<String> memberIdsOf(String bubbleId) {
    final rs = _db.db.select(
      "SELECT user_id FROM bubble_members WHERE bubble_id = ? AND status = 'accepted'",
      [bubbleId],
    );
    return rs.map((r) => r['user_id'] as String).toList();
  }

  BubbleMember? memberOf(String bubbleId, String userId) {
    final rs = _db.db.select(
      'SELECT * FROM bubble_members WHERE bubble_id = ? AND user_id = ?',
      [bubbleId, userId],
    );
    if (rs.isEmpty) return null;
    final r = rs.first;
    return BubbleMember(
      bubbleId: r['bubble_id'] as String,
      userId: r['user_id'] as String,
      role: r['role'] as String,
      status: r['status'] as String,
      joinedAt: DateTime.parse(r['joined_at'] as String),
    );
  }

  BubbleMember addMember(
    String bubbleId,
    String userId, {
    String role = 'user',
    String status = 'invited',
  }) {
    final now = DateTime.now().toUtc();
    _db.db.execute(
      '''
      INSERT INTO bubble_members (bubble_id, user_id, role, status, joined_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(bubble_id, user_id) DO UPDATE SET
        role   = excluded.role,
        status = excluded.status
      ''',
      [bubbleId, userId, role, status, now.toIso8601String()],
    );
    return memberOf(bubbleId, userId)!;
  }

  BubbleMember setStatus(String bubbleId, String userId, String status) {
    _db.db.execute(
      'UPDATE bubble_members SET status = ? WHERE bubble_id = ? AND user_id = ?',
      [status, bubbleId, userId],
    );
    return memberOf(bubbleId, userId)!;
  }

  void removeMember(String bubbleId, String userId) {
    _db.db.execute(
      'DELETE FROM bubble_members WHERE bubble_id = ? AND user_id = ?',
      [bubbleId, userId],
    );
  }

  BubbleMessage insertMessage({
    required String bubbleId,
    required String stanzaId,
    required Jid from,
    required String body,
    String? thread,
    String? subject,
  }) {
    final id = _ids.next();
    final now = DateTime.now().toUtc();
    _db.db.execute(
      '''
      INSERT INTO bubble_messages
        (id, bubble_id, stanza_id, from_jid, body, thread, subject, sent_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        id,
        bubbleId,
        stanzaId,
        from.bare.toString(),
        body,
        thread,
        subject,
        now.toIso8601String(),
      ],
    );
    return BubbleMessage(
      id: id,
      bubbleId: bubbleId,
      stanzaId: stanzaId,
      from: from,
      body: body,
      sentAt: now,
      thread: thread,
      subject: subject,
    );
  }

  List<BubbleMessage> historyFor(String bubbleId, {int limit = 100}) {
    final rs = _db.db.select(
      '''
      SELECT * FROM bubble_messages WHERE bubble_id = ?
      ORDER BY sent_at ASC LIMIT ?
      ''',
      [bubbleId, limit],
    );
    return rs.map(_rowToBubbleMessage).toList();
  }

  /// Returns the row matching [stanzaId] in [bubbleId], or null if none.
  BubbleMessage? findMessageByStanzaId(String bubbleId, String stanzaId) {
    final rs = _db.db.select(
      'SELECT * FROM bubble_messages WHERE bubble_id = ? AND stanza_id = ? '
      'LIMIT 1',
      [bubbleId, stanzaId],
    );
    if (rs.isEmpty) return null;
    return _rowToBubbleMessage(rs.first);
  }

  /// Deletes a bubble message by its stanza id. Used by XEP-0424 retract.
  bool deleteMessageByStanzaId(String bubbleId, String stanzaId) {
    _db.db.execute(
      'DELETE FROM bubble_messages WHERE bubble_id = ? AND stanza_id = ?',
      [bubbleId, stanzaId],
    );
    return _db.db.updatedRows > 0;
  }

  /// XEP-0425 moderation: record a tombstone and redact the archived body
  /// so MAM no longer serves the original content.
  void moderateMessage(
    String bubbleId,
    String stanzaId, {
    required String byJid,
    String? reason,
  }) {
    _db.db.execute(
      '''
      INSERT INTO moderations (bubble_id, stanza_id, by_jid, reason, moderated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(bubble_id, stanza_id) DO UPDATE SET
        by_jid = excluded.by_jid,
        reason = excluded.reason,
        moderated_at = excluded.moderated_at
      ''',
      [
        bubbleId,
        stanzaId,
        byJid,
        reason,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    _db.db.execute(
      "UPDATE bubble_messages SET body = '' "
      'WHERE bubble_id = ? AND stanza_id = ?',
      [bubbleId, stanzaId],
    );
  }

  Moderation? moderationFor(String bubbleId, String stanzaId) {
    final rs = _db.db.select(
      'SELECT by_jid, reason FROM moderations '
      'WHERE bubble_id = ? AND stanza_id = ?',
      [bubbleId, stanzaId],
    );
    if (rs.isEmpty) return null;
    return Moderation(
      byJid: rs.first['by_jid'] as String,
      reason: rs.first['reason'] as String?,
    );
  }

  /// XEP-0313 + RSM-aware slice for bubble history. No anchor or
  /// `<before>` returns the NEWEST [max] messages (in chronological
  /// ASC order within the page); `<after>` walks forward.
  ({List<BubbleMessage> page, int total}) mamSlice(
    String bubbleId, {
    int max = 50,
    String? beforeId,
    String? afterId,
  }) {
    final total =
        _db.db.select(
              'SELECT COUNT(*) AS n FROM bubble_messages WHERE bubble_id = ?',
              [bubbleId],
            ).first['n']
            as int;
    final params = <Object?>[bubbleId];
    var sql = 'SELECT * FROM bubble_messages WHERE bubble_id = ?';
    if (beforeId != null && beforeId.isNotEmpty) {
      final anchor = _findBmsgAnchor(beforeId);
      if (anchor != null) {
        sql += ' AND (sent_at < ? OR (sent_at = ? AND id < ?))';
        params
          ..add(anchor.sentAt)
          ..add(anchor.sentAt)
          ..add(anchor.id);
      }
    }
    if (afterId != null && afterId.isNotEmpty) {
      final anchor = _findBmsgAnchor(afterId);
      if (anchor != null) {
        sql += ' AND (sent_at > ? OR (sent_at = ? AND id > ?))';
        params
          ..add(anchor.sentAt)
          ..add(anchor.sentAt)
          ..add(anchor.id);
      }
    }
    final walkForward = afterId != null && afterId.isNotEmpty;
    sql += walkForward
        ? ' ORDER BY sent_at ASC, id ASC LIMIT ?'
        : ' ORDER BY sent_at DESC, id DESC LIMIT ?';
    params.add(max);
    final rs = _db.db.select(sql, params);
    var page = rs.map(_rowToBubbleMessage).toList();
    if (!walkForward) page = page.reversed.toList();
    return (page: page, total: total);
  }

  ({String id, String sentAt})? _findBmsgAnchor(String id) {
    final rs = _db.db.select(
      'SELECT id, sent_at FROM bubble_messages WHERE id = ?',
      [id],
    );
    if (rs.isEmpty) return null;
    return (
      id: rs.first['id'] as String,
      sentAt: rs.first['sent_at'] as String,
    );
  }

  BubbleMessage _rowToBubbleMessage(Map<String, Object?> r) => BubbleMessage(
    id: r['id'] as String,
    bubbleId: r['bubble_id'] as String,
    stanzaId: r['stanza_id'] as String,
    from: Jid.parse(r['from_jid'] as String),
    body: r['body'] as String,
    sentAt: DateTime.parse(r['sent_at'] as String),
    thread: r['thread'] as String?,
    subject: r['subject'] as String?,
  );

  Map<String, dynamic> bubbleToRainbowJson(
    Bubble b,
    List<BubbleMember> members,
  ) => {
    'id': b.id,
    'jid': '${b.id}@muc.rainbow-stub.local',
    'name': b.name,
    'topic': b.topic,
    'creator': b.ownerId,
    'visibility': b.visibility,
    'isArchived': b.archived,
    'creationDate': b.createdAt.toUtc().toIso8601String(),
    'lastAvatarUpdateDate': null,
    'users': members
        .map(
          (m) => {
            'userId': m.userId,
            'privilege': m.role,
            'status': m.status,
            'additionDate': m.joinedAt.toUtc().toIso8601String(),
          },
        )
        .toList(),
  };
}
