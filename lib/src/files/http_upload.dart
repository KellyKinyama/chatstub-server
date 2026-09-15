import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Thrown by [HttpUploadService.requestSlot] when the requested size
/// exceeds the configured cap — mapped to XEP-0363 `<file-too-large>`.
class FileTooLargeException implements Exception {
  FileTooLargeException(this.maxFileSize);
  final int maxFileSize;
}

class _Slot {
  _Slot({
    required this.filename,
    required this.contentType,
    required this.size,
  });
  final String filename;
  final String contentType;
  final int size;
  bool uploaded = false;
}

/// Minimal XEP-0363 HTTP File Upload backend. A slot request mints an
/// unguessable token; the client PUTs bytes to `/upload/<token>` and any
/// party GETs them back from the same URL. Slot metadata is in-memory
/// (ephemeral, like the rest of the stub); bytes live under [rootDir].
class HttpUploadService {
  HttpUploadService({required this.rootDir, required this.maxFileSize}) {
    Directory(rootDir).createSync(recursive: true);
  }

  final String rootDir;
  final int maxFileSize;
  final _slots = <String, _Slot>{};
  final _rng = Random.secure();

  String _path(String token) => '$rootDir${Platform.pathSeparator}$token';

  /// Reserves a slot and returns its token. Throws [FileTooLargeException]
  /// when [size] is over the cap.
  String requestSlot({
    required String filename,
    required int size,
    String? contentType,
  }) {
    if (size > maxFileSize) throw FileTooLargeException(maxFileSize);
    final token = _newToken();
    _slots[token] = _Slot(
      filename: _sanitize(filename),
      contentType: (contentType == null || contentType.isEmpty)
          ? 'application/octet-stream'
          : contentType,
      size: size,
    );
    return token;
  }

  bool hasSlot(String token) => _slots.containsKey(token);

  /// Stores uploaded bytes for [token]. Returns false when the token is
  /// unknown or the payload exceeds the cap.
  Future<bool> put(String token, Uint8List bytes) async {
    final slot = _slots[token];
    if (slot == null) return false;
    if (bytes.length > maxFileSize) return false;
    await File(_path(token)).writeAsBytes(bytes, flush: true);
    slot.uploaded = true;
    return true;
  }

  /// Returns stored bytes + content-type + filename, or null when the
  /// token is unknown or nothing has been uploaded yet.
  Future<({Uint8List bytes, String contentType, String filename})?> get(
    String token,
  ) async {
    final slot = _slots[token];
    if (slot == null || !slot.uploaded) return null;
    final f = File(_path(token));
    if (!await f.exists()) return null;
    return (
      bytes: await f.readAsBytes(),
      contentType: slot.contentType,
      filename: slot.filename,
    );
  }

  String _newToken() {
    final bytes = List<int>.generate(24, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _sanitize(String name) {
    final base = name.split(RegExp(r'[\\/]')).last.trim();
    if (base.isEmpty) return 'file';
    return base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }
}
