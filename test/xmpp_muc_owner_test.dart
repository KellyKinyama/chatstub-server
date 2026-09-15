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
const _mucOwnerNs = 'http://jabber.org/protocol/muc#owner';
const _mucUserNs = 'http://jabber.org/protocol/muc#user';
const _mucNs = 'http://jabber.org/protocol/muc';
const _formNs = 'jabber:x:data';

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
    final tempDir = Directory.systemTemp.createTempSync(
      'rainbow-stub-mucowner',
    );
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

  test(
    'joining a non-existent room creates it with the joiner as owner',
    () async {
      final alice = await connect(
        email: 'alice@rainbow-stub.local',
        token: aliceToken,
        resource: 'phone',
      );
      final selfP = alice.awaitSelfPresence();
      alice.send(
        '<presence to="team@muc.$_domain/$aliceId">'
        '<x xmlns="$_mucNs"/></presence>',
      );
      final p = await selfP;
      final x = p.getElement('x', namespace: _mucUserNs)!;
      final codes = x
          .findElements('status')
          .map((s) => s.getAttribute('code'))
          .toList();
      expect(codes, contains('110'));
      expect(codes, contains('201')); // freshly created

      final room = app.bubbles.findById('team');
      expect(room, isNotNull);
      expect(room!.ownerId, aliceId);
      expect(app.bubbles.memberOf('team', aliceId)?.role, 'owner');
      await alice.close();
    },
  );

  test('owner get returns a muc#roomconfig form', () async {
    app.bubbles.createWithId(id: 'team', ownerId: aliceId, name: 'Team');
    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final resp = await alice.iq(
      '<iq type="get" id="cfg1" to="team@muc.$_domain">'
          '<query xmlns="$_mucOwnerNs"/></iq>',
      'cfg1',
    );
    final form = resp
        .getElement('query', namespace: _mucOwnerNs)!
        .getElement('x', namespace: _formNs)!;
    expect(form.getAttribute('type'), 'form');
    final vars = form
        .findElements('field')
        .map((f) => f.getAttribute('var'))
        .toList();
    expect(vars, contains('muc#roomconfig_roomname'));
    expect(vars, contains('muc#roomconfig_membersonly'));
    await alice.close();
  });

  test('owner set applies name, description and members-only', () async {
    app.bubbles.createWithId(id: 'team', ownerId: aliceId, name: 'team');
    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    await alice.iq(
      '<iq type="set" id="cfg2" to="team@muc.$_domain">'
          '<query xmlns="$_mucOwnerNs">'
          '<x xmlns="$_formNs" type="submit">'
          '<field var="muc#roomconfig_roomname"><value>Team Room</value></field>'
          '<field var="muc#roomconfig_roomdesc"><value>Daily standup</value></field>'
          '<field var="muc#roomconfig_membersonly"><value>0</value></field>'
          '</x></query></iq>',
      'cfg2',
    );
    final room = app.bubbles.findById('team')!;
    expect(room.name, 'Team Room');
    expect(room.topic, 'Daily standup');
    expect(room.visibility, 'public');
    await alice.close();
  });

  test('a second user joins the public room and sees the subject', () async {
    app.bubbles.createWithId(
      id: 'team',
      ownerId: aliceId,
      name: 'Team',
      topic: 'Daily standup',
    );
    final bob = await connect(
      email: 'bob@rainbow-stub.local',
      token: bobToken,
      resource: 'web',
    );
    final subjectMsg = bob.stream.firstWhere(
      (e) => e.localName == 'message' && e.getElement('subject') != null,
    );
    bob.send(
      '<presence to="team@muc.$_domain/$bobId">'
      '<x xmlns="$_mucNs"/></presence>',
    );
    final msg = await subjectMsg.timeout(const Duration(seconds: 3));
    expect(msg.getElement('subject')?.innerText, 'Daily standup');
    // Bob was enrolled as an accepted member by the open join.
    expect(app.bubbles.memberOf('team', bobId)?.status, 'accepted');
    await bob.close();
  });

  test('a non-owner set is forbidden', () async {
    app.bubbles.createWithId(id: 'team', ownerId: aliceId, name: 'Team');
    final bob = await connect(
      email: 'bob@rainbow-stub.local',
      token: bobToken,
      resource: 'web',
    );
    final resp = await bob.iq(
      '<iq type="set" id="cfg3" to="team@muc.$_domain">'
          '<query xmlns="$_mucOwnerNs">'
          '<x xmlns="$_formNs" type="submit">'
          '<field var="muc#roomconfig_roomname"><value>Hijack</value></field>'
          '</x></query></iq>',
      'cfg3',
    );
    expect(resp.getAttribute('type'), 'error');
    expect(resp.getElement('error')?.getElement('forbidden'), isNotNull);
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

  Future<XmlElement> awaitSelfPresence() => stream
      .firstWhere((e) {
        if (e.localName != 'presence') return false;
        final x = e.getElement('x', namespace: _mucUserNs);
        if (x == null) return false;
        return x
            .findElements('status')
            .any((s) => s.getAttribute('code') == '110');
      })
      .timeout(const Duration(seconds: 3));

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
