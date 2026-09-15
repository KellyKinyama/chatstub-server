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
const _anonHost = 'anon.rainbow-stub.local';

Future<RainbowStubApp> _boot({required bool allowAnonymous}) async {
  final tempDir = Directory.systemTemp.createTempSync('rainbow-stub-anon');
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
    anonymous: allowAnonymous
        ? const AnonymousConfig(enabled: true, host: _anonHost)
        : const AnonymousConfig(),
  );
  return RainbowStubApp.boot(config);
}

void main() {
  late RainbowStubApp app;
  late HttpServer server;
  late String host;
  late int port;
  late String aliceId;
  late String aliceToken;

  setUp(() async {
    app = await _boot(allowAnonymous: true);
    final alice = app.users.create(
      loginEmail: 'alice@rainbow-stub.local',
      password: 'password',
      firstName: 'Alice',
      lastName: 'Sample',
    );
    aliceId = alice.id;
    aliceToken = app.tokens
        .issue(
          userId: aliceId,
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

  Future<_Xmpp> connectPlain({
    required String email,
    required String token,
    required String resource,
  }) async {
    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://$host:$port/websocket'),
      protocols: ['xmpp'],
    );
    await channel.ready;
    final c = _Xmpp(channel);
    await c.openStream();
    await c.saslPlain(email: email, password: token);
    await c.openStream();
    await c.bind(resource);
    return c;
  }

  Future<_Xmpp> connectAnonymous({String resource = 'guest'}) async {
    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://$host:$port/websocket'),
      protocols: ['xmpp'],
    );
    await channel.ready;
    final c = _Xmpp(channel);
    await c.openStream();
    await c.saslAnonymous();
    await c.openStream();
    await c.bind(resource);
    return c;
  }

  test('ANONYMOUS is advertised and a guest binds on the anon host', () async {
    final guest = await connectAnonymous();
    expect(guest.mechanisms, contains('ANONYMOUS'));
    expect(guest.mechanisms, contains('PLAIN'));
    expect(guest.jid, startsWith('guest-'));
    expect(guest.jid, endsWith('@$_anonHost/guest'));
    await guest.close();
  });

  test('two guests get distinct ephemeral JIDs', () async {
    final g1 = await connectAnonymous();
    final g2 = await connectAnonymous();
    expect(g1.jid, isNot(equals(g2.jid)));
    await g1.close();
    await g2.close();
  });

  test('guest <-> registered user exchange 1:1 chat both ways', () async {
    final alice = await connectPlain(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final guest = await connectAnonymous();

    // Guest -> Alice.
    final toAlice = alice.awaitLocal('message');
    guest.send(
      '<message id="m1" to="$aliceId@$_domain" type="chat">'
      '<body>hi from guest</body></message>',
    );
    final gotByAlice = await toAlice.timeout(const Duration(seconds: 3));
    expect(gotByAlice.getElement('body')?.innerText, 'hi from guest');
    expect(gotByAlice.getAttribute('from'), guest.jid);

    // Alice -> Guest (addressed at the guest's full ephemeral JID).
    final toGuest = guest.awaitLocal('message');
    alice.send(
      '<message id="m2" to="${guest.jid}" type="chat">'
      '<body>welcome guest</body></message>',
    );
    final gotByGuest = await toGuest.timeout(const Duration(seconds: 3));
    expect(gotByGuest.getElement('body')?.innerText, 'welcome guest');

    await alice.close();
    await guest.close();
  });

  test('ANONYMOUS is refused and unadvertised when disabled', () async {
    final app2 = await _boot(allowAnonymous: false);
    final server2 = await shelf_io.serve(app2.buildHandler(), '127.0.0.1', 0);
    addTearDown(() async {
      await server2.close(force: true);
      app2.db.close();
    });

    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://${server2.address.host}:${server2.port}/websocket'),
      protocols: ['xmpp'],
    );
    await channel.ready;
    final c = _Xmpp(channel);
    await c.openStream();
    expect(c.mechanisms, isNot(contains('ANONYMOUS')));

    final ready = c.stream.firstWhere(
      (e) => e.localName == 'success' || e.localName == 'failure',
    );
    c.send(
      '<auth xmlns="urn:ietf:params:xml:ns:xmpp-sasl" mechanism="ANONYMOUS"/>',
    );
    final r = await ready.timeout(const Duration(seconds: 3));
    expect(r.localName, 'failure');
    await c.close();
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
  List<String> mechanisms = const [];

  Stream<XmlElement> get stream => _controller.stream;

  void send(String s) => _channel.sink.add(s);

  Future<XmlElement> awaitLocal(String localName) =>
      stream.firstWhere((e) => e.localName == localName);

  Future<void> openStream() async {
    final ready = stream.firstWhere(
      (e) => e.localName == 'features' || e.localName == 'stream:features',
    );
    send(
      '<open xmlns="urn:ietf:params:xml:ns:xmpp-framing" '
      'to="$_domain" version="1.0"/>',
    );
    final feats = await ready.timeout(const Duration(seconds: 3));
    final mechs = feats
        .findAllElements('mechanism')
        .map((m) => m.innerText)
        .toList();
    if (mechs.isNotEmpty) mechanisms = mechs;
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

  Future<void> saslAnonymous() async {
    final ready = stream.firstWhere(
      (e) => e.localName == 'success' || e.localName == 'failure',
    );
    send(
      '<auth xmlns="urn:ietf:params:xml:ns:xmpp-sasl" mechanism="ANONYMOUS"/>',
    );
    final r = await ready.timeout(const Duration(seconds: 3));
    if (r.localName != 'success') {
      throw StateError('SASL ANONYMOUS failed: ${r.toXmlString()}');
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
    final iq = await ready.timeout(const Duration(seconds: 3));
    jid = iq.findAllElements('jid').first.innerText;
  }

  Future<void> close() async {
    await _sub.cancel();
    if (!_controller.isClosed) await _controller.close();
    await _channel.sink.close();
  }
}
