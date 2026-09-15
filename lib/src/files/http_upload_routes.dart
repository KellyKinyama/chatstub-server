import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'http_upload.dart';

/// XEP-0363 PUT/GET endpoints. Unauthenticated by design — the slot token
/// in the path is the capability. Mounted at `/upload/<token>`.
Router httpUploadRouter(HttpUploadService upload) {
  final r = Router();

  r.put('/upload/<token>', (Request req, String token) async {
    if (!upload.hasSlot(token)) {
      return Response.notFound('unknown slot');
    }
    final bytes = await _drain(req);
    final ok = await upload.put(token, bytes);
    if (!ok) {
      return Response(413, body: 'file too large or unknown slot');
    }
    return Response(201);
  });

  r.get('/upload/<token>', (Request req, String token) async {
    final blob = await upload.get(token);
    if (blob == null) return Response.notFound('not found');
    return Response.ok(
      blob.bytes,
      headers: {
        'content-type': blob.contentType,
        'content-disposition': 'attachment; filename="${blob.filename}"',
        'content-length': '${blob.bytes.length}',
      },
    );
  });

  return r;
}

Future<Uint8List> _drain(Request req) async {
  final chunks = <int>[];
  await for (final chunk in req.read()) {
    chunks.addAll(chunk);
  }
  return Uint8List.fromList(chunks);
}
