import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http_parser/http_parser.dart';
import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:shelf/shelf.dart';

import '../db/database.dart';

final _uploadLog = Logger('avatar.upload');

class AvatarBlob {
  AvatarBlob({
    required this.bytes,
    required this.mimeType,
    required this.updatedAt,
  });

  final Uint8List bytes;
  final String mimeType;
  final DateTime updatedAt;
}

class AvatarStore {
  AvatarStore({required this.rootDir, required AppDatabase db}) : _db = db {
    Directory(rootDir).createSync(recursive: true);
  }

  final String rootDir;
  final AppDatabase _db;

  String _path(String userId) => '$rootDir${Platform.pathSeparator}$userId';

  bool has(String userId) {
    final rs = _db.db.select('SELECT 1 FROM avatars WHERE user_id = ?', [
      userId,
    ]);
    return rs.isNotEmpty;
  }

  Future<AvatarBlob?> read(String userId) async {
    final rs = _db.db.select(
      'SELECT mime_type, updated_at FROM avatars WHERE user_id = ?',
      [userId],
    );
    if (rs.isEmpty) return null;
    final f = File(_path(userId));
    if (!await f.exists()) return null;
    return AvatarBlob(
      bytes: await f.readAsBytes(),
      mimeType: rs.first['mime_type'] as String,
      updatedAt: DateTime.parse(rs.first['updated_at'] as String),
    );
  }

  /// Synchronous variant used by the sync XMPP IQ dispatch (vCard PHOTO).
  AvatarBlob? readSync(String userId) {
    final rs = _db.db.select(
      'SELECT mime_type, updated_at FROM avatars WHERE user_id = ?',
      [userId],
    );
    if (rs.isEmpty) return null;
    final f = File(_path(userId));
    if (!f.existsSync()) return null;
    return AvatarBlob(
      bytes: f.readAsBytesSync(),
      mimeType: rs.first['mime_type'] as String,
      updatedAt: DateTime.parse(rs.first['updated_at'] as String),
    );
  }

  Future<void> write(String userId, Uint8List bytes, String mimeType) async {
    await File(_path(userId)).writeAsBytes(bytes, flush: true);
    _writeMeta(userId, bytes.length, mimeType);
  }

  /// Synchronous variant used by the sync XMPP IQ dispatch (vCard PHOTO set).
  void writeSync(String userId, Uint8List bytes, String mimeType) {
    File(_path(userId)).writeAsBytesSync(bytes, flush: true);
    _writeMeta(userId, bytes.length, mimeType);
  }

  void _writeMeta(String userId, int byteSize, String mimeType) {
    _db.db.execute(
      '''
      INSERT INTO avatars (user_id, mime_type, byte_size, updated_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(user_id) DO UPDATE SET
        mime_type = excluded.mime_type,
        byte_size = excluded.byte_size,
        updated_at = excluded.updated_at
      ''',
      [
        userId,
        mimeType,
        byteSize,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  Future<void> delete(String userId) async {
    _db.db.execute('DELETE FROM avatars WHERE user_id = ?', [userId]);
    final f = File(_path(userId));
    if (await f.exists()) await f.delete();
  }
}

/// Extracts the first file-part from a multipart/form-data body OR treats
/// the request body as raw bytes when the client uploaded octet-stream.
Future<({Uint8List bytes, String mimeType})> readUploadedImage(
  Request req,
) async {
  final ct = req.headers['content-type'];
  _uploadLog.fine('content-type=$ct');
  if (ct == null) {
    throw const FormatException('Missing content-type');
  }
  final mediaType = MediaType.parse(ct);
  if (mediaType.type == 'multipart') {
    final boundary = mediaType.parameters['boundary'];
    if (boundary == null) {
      throw const FormatException('Missing multipart boundary');
    }
    try {
      final parts = MimeMultipartTransformer(boundary).bind(req.read());
      await for (final part in parts) {
        final headers = part.headers;
        _uploadLog.fine('part headers=$headers');
        final disposition = headers['content-disposition'] ?? '';
        if (!disposition.contains('filename')) {
          // Drain and skip.
          await part.drain<void>();
          continue;
        }
        final partCt = headers['content-type'] ?? 'application/octet-stream';
        final buf = BytesBuilder();
        await for (final chunk in part) {
          buf.add(chunk);
        }
        _uploadLog.fine('read file part bytes=${buf.length} mime=$partCt');
        return (bytes: buf.toBytes(), mimeType: partCt);
      }
      throw const FormatException('No file part in multipart body');
    } catch (e, st) {
      _uploadLog.warning('multipart parse failed', e, st);
      rethrow;
    }
  }
  // Fallback: raw upload (application/octet-stream, image/*, …)
  final buf = BytesBuilder();
  await for (final chunk in req.read()) {
    buf.add(chunk);
  }
  return (bytes: buf.toBytes(), mimeType: mediaType.mimeType);
}

/// Extends a JSON response with a cache-buster query token derived from
/// the timestamp — the RN SDK uses this to invalidate cached avatars.
String avatarBust(DateTime updatedAt) =>
    updatedAt.microsecondsSinceEpoch.toRadixString(16);

/// Only used to keep `dart:convert` referenced when this file is trimmed.
// ignore: unused_element
String _keep(Object o) => jsonEncode(o);
