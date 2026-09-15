import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rainbow_stub/rainbow_stub.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xml/xml.dart';

const _domain = 'rainbow-stub.local';
const _uploadNs = 'urn:xmpp:http:upload:0';

void main() {
  late RainbowStubApp app;
  late HttpServer server;
  late String host;
  late int port;
  late String aliceToken;

  setUp(() async {
    final tempDir = Directory.systemTemp.createTempSync('rainbow-stub-upload');
    final config = Config(
      host: '127.0.0.1',
      port: 0,
      publicHost: _domain,
      tlsCertPath: 'certs/rainbow-stub.crt',
      tlsKeyPath: 'certs/rainbow-stub.key',
      dbPath: '${tempDir.path}/t.db',
      fileStorePath: '${tempDir.path}/files',
      avatarStorePath: '${tempDir.path}/avatars',
      auth: AuthConfig(
        appId: 'x',
        appSecret: 'x',
        tokenTtl: const Duration(hours: 24),
        renewTtl: const Duration(hours: 48),
      ),
      asterisk: AsteriskConfig(
        ariUrl: 'http://localhost:8088/asterisk/ari',
        ariUser: 'asterisk',
        ariPassword: 'asterisk',
        wsSipUrl: 'wss://localhost:8089/asterisk/ws',
        sipDomain: 'rainbow-stub',
      ),
      httpUpload: const HttpUploadConfig(maxFileSizeBytes: 1024),
    );
    app = await RainbowStubApp.boot(config);
    final alice = app.users.create(
      loginEmail: 'alice@rainbow-stub.local',
      password: 'password',
      firstName: 'Alice',
      lastName: 'Sample',
    );
    aliceToken = app.tokens
        .issue(
          userId: alice.id,
          ttl: const Duration(hours: 1),
          renewTtl: const Duration(hours: 2),
        )
        .token;
    server = await shelf_io.serve(app.buildHandler(), '127.0.0.1', 0);
    host = server.address.host;
    port = server.port;
  });

  tearDown(() async {
    await server.close(force: true);
    app.db.close();
  });

  Future<_Xmpp> connect() async {
    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://$host:$port/websocket'),
      protocols: ['xmpp'],
    );
    await channel.ready;
    final c = _Xmpp(channel);
    await c.openStream();
    await c.saslPlain(
      email: 'alice@rainbow-stub.local',
      password: aliceToken,
    );
    await c.openStream();
    await c.bind('phone');
    return c;
  }

  // The slot URL embeds config.publicBaseUrl (host/port from config), so
  // rewrite it onto the ephemeral test server to actually hit it.
  Uri _local(String url) {
    final u = Uri.parse(url);
    return Uri.parse('http://$host:$port${u.path}');
  }

  test('disco#info advertises http:upload with a max-file-size form',
      () async {
    final alice = await connect();
    final resp = await alice.iq(
      '<iq type="get" id="d1" to="$_domain">'
      '<query xmlns="http://jabber.org/protocol/disco#info"/></iq>',
      'd1',
    );
    final query = resp.getElement('query')!;
    final feats = query
        .findElements('feature')
        .map((f) => f.getAttribute('var'))
        .toList();
    expect(feats, contains(_uploadNs));
    final form = query.getElement('x', namespace: 'jabber:x:data')!;
    final maxField = form
        .findElements('field')
        .firstWhere((f) => f.getAttribute('var') == 'max-file-size');
    expect(maxField.getElement('value')?.innerText, '1024');
    await alice.close();
  });

  test('slot request → PUT then GET round-trips the bytes', () async {
    final alice = await connect();
    final bytes = utf8.encode('hello upload');
    final resp = await alice.iq(
      '<iq type="get" id="s1">'
      '<request xmlns="$_uploadNs" filename="note.txt" '
      'size="${bytes.length}" content-type="text/plain"/></iq>',
      's1',
    );
    final slot = resp.getElement('slot', namespace: _uploadNs)!;
    final putUrl = slot.getElement('put')!.getAttribute('url')!;
    final getUrl = slot.getElement('get')!.getAttribute('url')!;
    expect(putUrl, contains('/upload/'));

    final client = HttpClient();
    final put = await client.putUrl(_local(putUrl));
    put.headers.contentType = ContentType('text', 'plain');
    put.add(bytes);
    final putResp = await put.close();
    expect(putResp.statusCode, 201);
    await putResp.drain<void>();

    final get = await client.getUrl(_local(getUrl));
    final getResp = await get.close();
    expect(getResp.statusCode, 200);
    expect(getResp.headers.contentType?.mimeType, 'text/plain');
    final got = await getResp.fold<List<int>>(
      <int>[],
      (a, b) => a..addAll(b),
    );
    expect(utf8.decode(got), 'hello upload');
    client.close();
    await alice.close();
  });

  test('slot request over the cap returns file-too-large', () async {
    final alice = await connect();
    final resp = await alice.iq(
      '<iq type="get" id="s2">'
      '<request xmlns="$_uploadNs" filename="big.bin" '
      'size="99999" content-type="application/octet-stream"/></iq>',
      's2',
    );
    expect(resp.getAttribute('type'), 'error');
    final tooLarge = resp
        .getElement('error')
        ?.getElement('file-too-large', namespace: _uploadNs);
    expect(tooLarge, isNotNull);
    expect(tooLarge?.getElement('max-file-size')?.innerText, '1024');
    await alice.close();
  });

  test('GET on an unknown token is 404', () async {
    final client = HttpClient();
    final get = await client.getUrl(
      Uri.parse('http://$host:$port/upload/deadbeef'),
    );
    final resp = await get.close();
    expect(resp.statusCode, 404);
    await resp.drain<void>();
    client.close();
  });
}

class _Xmpp {
  _Xmpp(this._channel) {
    _sub = _channel.stream.listen(
      (raw) {
        final text = raw is List<int> ? utf8.decode(raw) : raw as String;
        final XmlDocument doc;
        try {
          doc = XmlDocument.parse(text);
        } on XmlException {
          return;
        }
        _controller.add(doc.rootElement);
      },
      onDone: () {
        if (!_controller.isClosed) _controller.close();
      },
    );
  }

  final WebSocketChannel _channel;
  late final StreamSubscription _sub;
  final _controller = StreamController<XmlElement>.broadcast();
  String jid = '';

  Stream<XmlElement> get stream => _controller.stream;

  void send(String s) => _channel.sink.add(s);

  Future<XmlElement> iq(String stanza, String id) {
    final ready = stream.firstWhere(
      (e) => e.localName == 'iq' && e.getAttribute('id') == id,
    );
    send(stanza);
    return ready.timeout(const Duration(seconds: 3));
  }

  Future<void> openStream() async {
    final ready = stream.firstWhere(
      (e) => e.localName == 'features' || e.localName == 'stream:features',
    );
    send(
      '<open xmlns="urn:ietf:params:xml:ns:xmpp-framing" '
      'to="$_domain" version="1.0"/>',
    );
    await ready.timeout(const Duration(seconds: 3));
  }

  Future<void> saslPlain({
    required String email,
    required String password,
  }) async {
    final ready = stream.firstWhere(
      (e) => e.localName == 'success' || e.localName == 'failure',
    );
    final payload = base64.encode(utf8.encode('\u0000$email\u0000$password'));
    send(
      '<auth xmlns="urn:ietf:params:xml:ns:xmpp-sasl" '
      'mechanism="PLAIN">$payload</auth>',
    );
    final r = await ready.timeout(const Duration(seconds: 3));
    if (r.localName != 'success') {
      throw StateError('SASL failed: ${r.toXmlString()}');
    }
  }

  Future<void> bind(String resource) async {
    final ready = stream.firstWhere(
      (e) => e.localName == 'iq' && e.getAttribute('type') == 'result',
    );
    send(
      '<iq type="set" id="bind1">'
      '<bind xmlns="urn:ietf:params:xml:ns:xmpp-bind">'
      '<resource>$resource</resource></bind></iq>',
    );
    final iqEl = await ready.timeout(const Duration(seconds: 3));
    jid = iqEl.findAllElements('jid').first.innerText;
  }

  Future<void> close() async {
    await _sub.cancel();
    if (!_controller.isClosed) await _controller.close();
    await _channel.sink.close();
  }
}
