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
const _sidNs = 'urn:xmpp:sid:0';
const _hintsNs = 'urn:xmpp:hints';
const _mamNs = 'urn:xmpp:mam:2';

void main() {
  late RainbowStubApp app;
  late HttpServer server;
  late String host;
  late int port;
  late String aliceId;
  late String bobId;
  late String aliceToken;
  late String bobToken;

  setUp(() async {
    final tempDir = Directory.systemTemp.createTempSync('rainbow-stub-sid');
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
    );
    app = await RainbowStubApp.boot(config);
    final alice = app.users.create(
      loginEmail: 'alice@rainbow-stub.local',
      password: 'password',
      firstName: 'Alice',
      lastName: 'Sample',
    );
    final bob = app.users.create(
      loginEmail: 'bob@rainbow-stub.local',
      password: 'password',
      firstName: 'Bob',
      lastName: 'Marley',
    );
    aliceId = alice.id;
    bobId = bob.id;
    aliceToken = app.tokens
        .issue(
          userId: aliceId,
          ttl: const Duration(hours: 1),
          renewTtl: const Duration(hours: 2),
        )
        .token;
    bobToken = app.tokens
        .issue(
          userId: bobId,
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

  Future<_Xmpp> connect({
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

  test('disco advertises urn:xmpp:sid:0', () async {
    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final resp = await alice.iq(
      '<iq type="get" id="d1" to="$_domain">'
      '<query xmlns="http://jabber.org/protocol/disco#info"/></iq>',
      'd1',
    );
    final feats = resp
        .getElement('query')!
        .findElements('feature')
        .map((f) => f.getAttribute('var'))
        .toList();
    expect(feats, contains(_sidNs));
    await alice.close();
  });

  test('a live 1:1 message carries a stanza-id stamped by the recipient',
      () async {
    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final bob = await connect(
      email: 'bob@rainbow-stub.local',
      token: bobToken,
      resource: 'web',
    );
    final got = bob.awaitWhere(
      (e) => e.localName == 'message' && e.getElement('body') != null,
    );
    alice.send(
      '<message id="c1" to="$bobId@$_domain" type="chat">'
      '<body>hi bob</body></message>',
    );
    final msg = await got;
    final sid = msg.getElement('stanza-id', namespace: _sidNs)!;
    expect(sid.getAttribute('id'), 'c1');
    expect(sid.getAttribute('by'), '$bobId@$_domain');
    await alice.close();
    await bob.close();
  });

  test('a live groupchat message carries a stanza-id stamped by the room',
      () async {
    app.bubbles.createWithId(id: 'team', ownerId: aliceId, name: 'Team');
    app.bubbles.addMember('team', bobId, role: 'user', status: 'accepted');
    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final bob = await connect(
      email: 'bob@rainbow-stub.local',
      token: bobToken,
      resource: 'web',
    );
    final got = bob.awaitWhere(
      (e) => e.localName == 'message' && e.getElement('body') != null,
    );
    alice.send(
      '<message id="g1" to="team@muc.$_domain" type="groupchat">'
      '<body>hi team</body></message>',
    );
    final msg = await got;
    final sid = msg.getElement('stanza-id', namespace: _sidNs)!;
    expect(sid.getAttribute('id'), 'g1');
    expect(sid.getAttribute('by'), 'team@muc.$_domain');
    await alice.close();
    await bob.close();
  });

  test('a <no-store> message is delivered but not archived', () async {
    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final bob = await connect(
      email: 'bob@rainbow-stub.local',
      token: bobToken,
      resource: 'web',
    );

    // Ephemeral message — delivered live, must not be archived.
    final ephemeral = bob.awaitWhere(
      (e) =>
          e.localName == 'message' &&
          e.getElement('body')?.innerText == 'ephemeral',
    );
    alice.send(
      '<message id="ns1" to="$bobId@$_domain" type="chat">'
      '<body>ephemeral</body>'
      '<no-store xmlns="$_hintsNs"/></message>',
    );
    await ephemeral;

    // Normal message — archived.
    final kept = bob.awaitWhere(
      (e) =>
          e.localName == 'message' &&
          e.getElement('body')?.innerText == 'kept',
    );
    alice.send(
      '<message id="keep1" to="$bobId@$_domain" type="chat">'
      '<body>kept</body></message>',
    );
    await kept;

    final results = await alice.mamCollect(
      '<iq type="set" id="mam1"><query xmlns="$_mamNs">'
      '<x xmlns="jabber:x:data" type="submit">'
      '<field var="FORM_TYPE"><value>$_mamNs</value></field>'
      '<field var="with"><value>$bobId@$_domain</value></field>'
      '</x></query></iq>',
      'mam1',
    );
    final bodies = results
        .map((r) => r
            .getElement('result', namespace: _mamNs)
            ?.getElement('forwarded')
            ?.getElement('message')
            ?.getElement('body')
            ?.innerText)
        .whereType<String>()
        .toList();
    expect(bodies, contains('kept'));
    expect(bodies, isNot(contains('ephemeral')));

    await alice.close();
    await bob.close();
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

  Future<XmlElement> awaitWhere(bool Function(XmlElement) test) =>
      stream.firstWhere(test).timeout(const Duration(seconds: 3));

  Future<List<XmlElement>> mamCollect(String stanza, String iqId) async {
    final results = <XmlElement>[];
    final done = Completer<List<XmlElement>>();
    late StreamSubscription sub;
    sub = stream.listen((e) {
      if (e.localName == 'message' &&
          e.getElement('result', namespace: _mamNs) != null) {
        results.add(e);
      } else if (e.localName == 'iq' && e.getAttribute('id') == iqId) {
        if (!done.isCompleted) done.complete(results);
      }
    });
    send(stanza);
    final out = await done.future.timeout(const Duration(seconds: 3));
    await sub.cancel();
    return out;
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
