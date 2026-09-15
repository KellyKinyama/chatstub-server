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
const _fastenNs = 'urn:xmpp:fasten:0';
const _moderateNs = 'urn:xmpp:message-moderate:0';
const _retract0Ns = 'urn:xmpp:message-retract:0';
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
    final tempDir = Directory.systemTemp.createTempSync(
      'rainbow-stub-moderate',
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
    // Room owned by alice; bob is an accepted member.
    app.bubbles.createWithId(id: 'team', ownerId: aliceId, name: 'Team');
    app.bubbles.addMember('team', bobId, role: 'user', status: 'accepted');
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

  test('owner moderation fans out a tombstone to occupants', () async {
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

    // Bob posts a message that alice will moderate.
    final aliceGotMsg = alice.awaitWhere(
      (e) => e.localName == 'message' && e.getElement('body') != null,
    );
    bob.send(
      '<message id="msg1" to="team@muc.$_domain" type="groupchat">'
      '<body>spam spam spam</body></message>',
    );
    await aliceGotMsg;

    // Alice (owner) moderates it.
    final bobGotTombstone = bob.awaitWhere(
      (e) =>
          e.localName == 'message' &&
          e.getElement('apply-to', namespace: _fastenNs) != null,
    );
    final ack = await alice.iq(
      '<iq type="set" id="mod1" to="team@muc.$_domain">'
          '<apply-to xmlns="$_fastenNs" id="msg1">'
          '<moderate xmlns="$_moderateNs">'
          '<retract xmlns="$_retract0Ns"/><reason>spam</reason>'
          '</moderate></apply-to></iq>',
      'mod1',
    );
    expect(ack.getAttribute('type'), 'result');

    final tomb = await bobGotTombstone.timeout(const Duration(seconds: 3));
    final applyTo = tomb.getElement('apply-to', namespace: _fastenNs)!;
    expect(applyTo.getAttribute('id'), 'msg1');
    final moderated = applyTo.getElement('moderated', namespace: _moderateNs)!;
    expect(moderated.getElement('retract', namespace: _retract0Ns), isNotNull);
    expect(moderated.getAttribute('by'), '$aliceId@$_domain');
    expect(moderated.getElement('reason')?.innerText, 'spam');

    await alice.close();
    await bob.close();
  });

  test('a later MAM query returns the tombstone instead of the body', () async {
    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final aliceGotMsg = alice.awaitWhere(
      (e) => e.localName == 'message' && e.getElement('body') != null,
    );
    // Alice posts then moderates her own message (owner can moderate any).
    alice.send(
      '<message id="msg2" to="team@muc.$_domain" type="groupchat">'
      '<body>to be removed</body></message>',
    );
    await aliceGotMsg;
    await alice.iq(
      '<iq type="set" id="mod2" to="team@muc.$_domain">'
          '<apply-to xmlns="$_fastenNs" id="msg2">'
          '<moderate xmlns="$_moderateNs"><retract xmlns="$_retract0Ns"/>'
          '<reason>cleanup</reason></moderate></apply-to></iq>',
      'mod2',
    );

    // Fresh member queries MAM for the room.
    final bob = await connect(
      email: 'bob@rainbow-stub.local',
      token: bobToken,
      resource: 'web',
    );
    final results = await bob.mamCollect(
      '<iq type="set" id="mam1"><query xmlns="$_mamNs">'
          '<x xmlns="jabber:x:data" type="submit">'
          '<field var="FORM_TYPE"><value>$_mamNs</value></field>'
          '<field var="with"><value>team@muc.$_domain</value></field>'
          '</x></query></iq>',
      'mam1',
    );
    final forwardedMsgs = results
        .map(
          (r) => r
              .getElement('result', namespace: _mamNs)
              ?.getElement('forwarded')
              ?.getElement('message'),
        )
        .whereType<XmlElement>()
        .toList();
    expect(forwardedMsgs, isNotEmpty);
    final msg = forwardedMsgs.first;
    expect(msg.getElement('apply-to', namespace: _fastenNs), isNotNull);
    expect(msg.getElement('body'), isNull);

    await alice.close();
    await bob.close();
  });

  test('a non-owner moderation attempt is forbidden', () async {
    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final aliceGotMsg = alice.awaitWhere(
      (e) => e.localName == 'message' && e.getElement('body') != null,
    );
    alice.send(
      '<message id="msg3" to="team@muc.$_domain" type="groupchat">'
      '<body>legit message</body></message>',
    );
    await aliceGotMsg;

    final bob = await connect(
      email: 'bob@rainbow-stub.local',
      token: bobToken,
      resource: 'web',
    );
    final resp = await bob.iq(
      '<iq type="set" id="mod3" to="team@muc.$_domain">'
          '<apply-to xmlns="$_fastenNs" id="msg3">'
          '<moderate xmlns="$_moderateNs"><retract xmlns="$_retract0Ns"/>'
          '</moderate></apply-to></iq>',
      'mod3',
    );
    expect(resp.getAttribute('type'), 'error');
    expect(resp.getElement('error')?.getElement('forbidden'), isNotNull);
    // Message is untouched.
    expect(
      app.bubbles.findMessageByStanzaId('team', 'msg3')?.body,
      'legit message',
    );
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

  /// Sends a MAM query and collects every result `<message>` until the
  /// terminating `<iq>` with [iqId] arrives.
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
