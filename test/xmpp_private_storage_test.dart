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
const _privateNs = 'jabber:iq:private';
const _bookmarksNs = 'storage:bookmarks';

void main() {
  late RainbowStubApp app;
  late HttpServer server;
  late String host;
  late int port;
  late String aliceToken;

  setUp(() async {
    final tempDir = Directory.systemTemp.createTempSync('rainbow-stub-private');
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
      anonymous: const AnonymousConfig(enabled: true),
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

  Future<_Xmpp> connectPlain() async {
    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://$host:$port/websocket'),
      protocols: ['xmpp'],
    );
    await channel.ready;
    final c = _Xmpp(channel);
    await c.openStream();
    await c.saslPlain(email: 'alice@rainbow-stub.local', password: aliceToken);
    await c.openStream();
    await c.bind('phone');
    return c;
  }

  Future<_Xmpp> connectAnonymous() async {
    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://$host:$port/websocket'),
      protocols: ['xmpp'],
    );
    await channel.ready;
    final c = _Xmpp(channel);
    await c.openStream();
    await c.saslAnonymous();
    await c.openStream();
    await c.bind('guest');
    return c;
  }

  test('empty bookmarks get returns an empty storage element', () async {
    final alice = await connectPlain();
    final resp = await alice.iq(
      '<iq type="get" id="b0"><query xmlns="$_privateNs">'
          '<storage xmlns="$_bookmarksNs"/></query></iq>',
      'b0',
    );
    final storage = resp
        .getElement('query', namespace: _privateNs)!
        .getElement('storage', namespace: _bookmarksNs)!;
    expect(storage.childElements, isEmpty);
    await alice.close();
  });

  test('bookmarks set then get round-trips conferences', () async {
    final alice = await connectPlain();
    await alice.iq(
      '<iq type="set" id="b1"><query xmlns="$_privateNs">'
          '<storage xmlns="$_bookmarksNs">'
          '<conference jid="team@muc.$_domain" autojoin="true" name="Team">'
          '<nick>ali</nick></conference>'
          '<conference jid="vip@muc.$_domain" autojoin="false" name="VIP"/>'
          '</storage></query></iq>',
      'b1',
    );

    // Fresh session sees the persisted bookmarks.
    final alice2 = await connectPlain();
    final resp = await alice2.iq(
      '<iq type="get" id="b2"><query xmlns="$_privateNs">'
          '<storage xmlns="$_bookmarksNs"/></query></iq>',
      'b2',
    );
    final confs = resp
        .getElement('query', namespace: _privateNs)!
        .getElement('storage', namespace: _bookmarksNs)!
        .findElements('conference')
        .toList();
    expect(confs, hasLength(2));
    expect(confs[0].getAttribute('jid'), 'team@muc.$_domain');
    expect(confs[0].getAttribute('autojoin'), 'true');
    expect(confs[0].getAttribute('name'), 'Team');
    expect(confs[0].getElement('nick')?.innerText, 'ali');
    expect(confs[1].getAttribute('jid'), 'vip@muc.$_domain');

    await alice.close();
    await alice2.close();
  });

  test('set overwrites the previous bookmark list', () async {
    final alice = await connectPlain();
    await alice.iq(
      '<iq type="set" id="c1"><query xmlns="$_privateNs">'
          '<storage xmlns="$_bookmarksNs">'
          '<conference jid="old@muc.$_domain" autojoin="true" name="Old"/>'
          '</storage></query></iq>',
      'c1',
    );
    await alice.iq(
      '<iq type="set" id="c2"><query xmlns="$_privateNs">'
          '<storage xmlns="$_bookmarksNs">'
          '<conference jid="new@muc.$_domain" autojoin="true" name="New"/>'
          '</storage></query></iq>',
      'c2',
    );
    final resp = await alice.iq(
      '<iq type="get" id="c3"><query xmlns="$_privateNs">'
          '<storage xmlns="$_bookmarksNs"/></query></iq>',
      'c3',
    );
    final confs = resp
        .getElement('query', namespace: _privateNs)!
        .getElement('storage', namespace: _bookmarksNs)!
        .findElements('conference')
        .toList();
    expect(confs, hasLength(1));
    expect(confs[0].getAttribute('jid'), 'new@muc.$_domain');
    await alice.close();
  });

  test('anonymous guest cannot set private storage', () async {
    final guest = await connectAnonymous();
    final resp = await guest.iq(
      '<iq type="set" id="g1"><query xmlns="$_privateNs">'
          '<storage xmlns="$_bookmarksNs">'
          '<conference jid="x@muc.$_domain" autojoin="true" name="X"/>'
          '</storage></query></iq>',
      'g1',
    );
    expect(resp.getAttribute('type'), 'error');
    expect(resp.getElement('error')?.getElement('forbidden'), isNotNull);
    await guest.close();
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
    final iqEl = await ready.timeout(const Duration(seconds: 3));
    jid = iqEl.findAllElements('jid').first.innerText;
  }

  Future<void> close() async {
    await _sub.cancel();
    if (!_controller.isClosed) await _controller.close();
    await _channel.sink.close();
  }
}
