import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:rainbow_stub/rainbow_stub.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xml/xml.dart';

const _domain = 'rainbow-stub.local';

void main() {
  late RainbowStubApp app;
  late HttpServer server;
  late String host;
  late int port;
  late String aliceId;
  late String bobId;
  late String aliceToken;
  late String bobToken;

  setUpAll(() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((r) {
      final err = r.error != null ? ' err=${r.error}' : '';
      // ignore: avoid_print
      print('${r.level.name} ${r.loggerName} ${r.message}$err');
    });
  });

  setUp(() async {
    final tempDir = Directory.systemTemp.createTempSync('rainbow-stub-p3');
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
    final wsUri = Uri.parse('ws://$host:$port/websocket');
    final channel = IOWebSocketChannel.connect(wsUri, protocols: ['xmpp']);
    await channel.ready;
    final c = _Xmpp(channel);
    await c.openStream();
    await c.saslPlain(email: email, password: token);
    await c.openStream();
    await c.bind(resource);
    return c;
  }

  test(
    'SASL PLAIN with bearer token binds to <userId>@domain/resource',
    () async {
      final alice = await connect(
        email: 'alice@rainbow-stub.local',
        token: aliceToken,
        resource: 'phone',
      );
      expect(alice.jid, '$aliceId@$_domain/phone');
      await alice.close();
    },
  );

  test('1:1 message from alice reaches bob and persists', () async {
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
    final delivered = bob.awaitLocal('message');
    alice.send(
      '<message id="m1" to="$bobId@$_domain" type="chat">'
      '<body>hello bob</body>'
      '</message>',
    );
    final msg = await delivered.timeout(const Duration(seconds: 3));
    expect(msg.getAttribute('from'), '$aliceId@$_domain/phone');
    expect(msg.getElement('body')?.innerText, 'hello bob');

    final aliceJid = Jid.parse('$aliceId@$_domain');
    final bobJid = Jid.parse('$bobId@$_domain');
    final persisted = app.messages.conversationBetween(aliceJid, bobJid);
    expect(persisted, hasLength(1));
    expect(persisted.first.body, 'hello bob');

    await alice.close();
    await bob.close();
  });

  test('presence broadcasts to peer sessions and updates repository', () async {
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
    final delivered = bob.awaitLocal('presence');
    alice.send('<presence><show>away</show><status>lunch</status></presence>');
    final pres = await delivered.timeout(const Duration(seconds: 3));
    expect(pres.getAttribute('from'), '$aliceId@$_domain/phone');
    expect(pres.getElement('show')?.innerText, 'away');
    expect(pres.getElement('status')?.innerText, 'lunch');
    expect(app.presence.findOrDefault(aliceId).show, 'away');
    await alice.close();
    await bob.close();
  });

  test('MAM query returns prior conversation ordered by time', () async {
    final aliceJid = Jid.parse('$aliceId@$_domain');
    final bobJid = Jid.parse('$bobId@$_domain');
    app.messages.insert(
      from: aliceJid,
      to: bobJid,
      stanzaId: 'x1',
      body: 'one',
    );
    app.messages.insert(
      from: bobJid,
      to: aliceJid,
      stanzaId: 'x2',
      body: 'two',
    );
    app.messages.insert(
      from: aliceJid,
      to: bobJid,
      stanzaId: 'x3',
      body: 'three',
    );

    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );

    final bodies = <String>[];
    final done = Completer<void>();
    late StreamSubscription sub;
    sub = alice.stream.listen((e) {
      if (e.localName == 'message') {
        for (final b in e.findAllElements('body')) {
          bodies.add(b.innerText);
        }
      } else if (e.localName == 'iq' && e.getAttribute('id') == 'mam1') {
        done.complete();
      }
    });
    alice.send(
      '<iq type="set" id="mam1">'
      '<query xmlns="urn:xmpp:mam:2">'
      '<x xmlns="jabber:x:data" type="submit">'
      '<field var="with"><value>$bobId@$_domain</value></field>'
      '</x></query></iq>',
    );
    await done.future.timeout(const Duration(seconds: 3));
    await sub.cancel();
    expect(bodies, ['one', 'two', 'three']);
    await alice.close();
  });

  test('unknown IQ get/set returns service-unavailable error', () async {
    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final done = Completer<XmlElement>();
    late StreamSubscription sub;
    sub = alice.stream.listen((e) {
      if (e.localName == 'iq' && e.getAttribute('id') == 'u1') {
        done.complete(e);
      }
    });
    alice.send(
      '<iq type="get" id="u1">'
      '<query xmlns="urn:example:unknown:nonsense"/>'
      '</iq>',
    );
    final resp = await done.future.timeout(const Duration(seconds: 3));
    await sub.cancel();
    expect(resp.getAttribute('type'), 'error');
    final err = resp.getElement('error');
    expect(err, isNotNull);
    expect(err!.getAttribute('type'), 'cancel');
    expect(
      err.getElement(
        'service-unavailable',
        namespace: 'urn:ietf:params:xml:ns:xmpp-stanzas',
      ),
      isNotNull,
    );
    await alice.close();
  });

  test('presence subscribe/subscribed is routed to the peer', () async {
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

    final bobGetsSubscribe = bob.awaitLocal('presence');
    alice.send('<presence to="$bobId@$_domain" type="subscribe"/>');
    final sub = await bobGetsSubscribe.timeout(const Duration(seconds: 3));
    expect(sub.getAttribute('type'), 'subscribe');
    expect(sub.getAttribute('from'), '$aliceId@$_domain');

    final aliceGetsApproved = alice.awaitLocal('presence');
    bob.send('<presence to="$aliceId@$_domain" type="subscribed"/>');
    final approved = await aliceGetsApproved.timeout(
      const Duration(seconds: 3),
    );
    expect(approved.getAttribute('type'), 'subscribed');
    expect(approved.getAttribute('from'), '$bobId@$_domain');

    await alice.close();
    await bob.close();
  });

  test('presence probe returns the target current presence', () async {
    final bob = await connect(
      email: 'bob@rainbow-stub.local',
      token: bobToken,
      resource: 'web',
    );
    bob.send('<presence><show>away</show><status>brb</status></presence>');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final probed = alice.awaitLocal('presence');
    alice.send('<presence to="$bobId@$_domain" type="probe"/>');
    final pres = await probed.timeout(const Duration(seconds: 3));
    expect(pres.getAttribute('from'), '$bobId@$_domain');
    expect(pres.getElement('show')?.innerText, 'away');

    await alice.close();
    await bob.close();
  });

  test('XEP-0012 last activity returns 0 for an online peer', () async {
    final bob = await connect(
      email: 'bob@rainbow-stub.local',
      token: bobToken,
      resource: 'web',
    );
    bob.send('<presence/>');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final done = Completer<XmlElement>();
    late StreamSubscription sub;
    sub = alice.stream.listen((e) {
      if (e.localName == 'iq' && e.getAttribute('id') == 'last1') {
        done.complete(e);
      }
    });
    alice.send(
      '<iq type="get" id="last1" to="$bobId@$_domain">'
      '<query xmlns="jabber:iq:last"/></iq>',
    );
    final resp = await done.future.timeout(const Duration(seconds: 3));
    await sub.cancel();
    final q = resp.getElement('query', namespace: 'jabber:iq:last');
    expect(q, isNotNull);
    expect(q!.getAttribute('seconds'), '0');

    await alice.close();
    await bob.close();
  });

  test('XEP-0012 last activity grows after the peer goes offline', () async {
    final bob = await connect(
      email: 'bob@rainbow-stub.local',
      token: bobToken,
      resource: 'web',
    );
    bob.send('<presence/>');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await bob.close();
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final done = Completer<XmlElement>();
    late StreamSubscription sub;
    sub = alice.stream.listen((e) {
      if (e.localName == 'iq' && e.getAttribute('id') == 'last2') {
        done.complete(e);
      }
    });
    alice.send(
      '<iq type="get" id="last2" to="$bobId@$_domain">'
      '<query xmlns="jabber:iq:last"/></iq>',
    );
    final resp = await done.future.timeout(const Duration(seconds: 3));
    await sub.cancel();
    final secs = int.parse(
      resp.getElement('query', namespace: 'jabber:iq:last')!.getAttribute(
        'seconds',
      )!,
    );
    expect(secs, greaterThanOrEqualTo(1));

    await alice.close();
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
    final iq = await ready.timeout(const Duration(seconds: 3));
    jid = iq.findAllElements('jid').first.innerText;
  }

  Future<void> close() async {
    await _sub.cancel();
    if (!_controller.isClosed) await _controller.close();
    await _channel.sink.close();
  }
}
