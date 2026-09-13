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
    final tempDir = Directory.systemTemp.createTempSync('rainbow-stub-p6');
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
    final uri = Uri.parse('ws://$host:$port/websocket');
    final channel = IOWebSocketChannel.connect(uri, protocols: ['xmpp']);
    await channel.ready;
    final c = _Xmpp(channel);
    await c.openStream();
    await c.saslPlain(email: email, password: token);
    await c.openStream();
    await c.bind(resource);
    return c;
  }

  // -------- XEP-0198 stream management --------------------------------------

  test(
    'XEP-0198: <enable/> → <enabled/> with id + counters advertised',
    () async {
      final alice = await connect(
        email: 'alice@rainbow-stub.local',
        token: aliceToken,
        resource: 'phone',
      );
      final ready = alice.awaitLocal('enabled');
      alice.send('<enable xmlns="urn:xmpp:sm:3" resume="true"/>');
      final enabled = await ready.timeout(const Duration(seconds: 3));
      expect(enabled.getAttribute('id'), isNotEmpty);
      expect(enabled.getAttribute('resume'), 'true');
      await alice.close();
    },
  );

  test('XEP-0198: <r/> → <a h=…/> tracks inbound stanza counter', () async {
    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    alice.send('<enable xmlns="urn:xmpp:sm:3"/>');
    await alice.awaitLocal('enabled').timeout(const Duration(seconds: 3));

    // Send two stanzas → hIn should be 2.
    alice.send('<presence/>');
    alice.send(
      '<iq type="get" id="p1" to="$_domain"><ping xmlns="urn:xmpp:ping"/></iq>',
    );
    await alice.awaitLocal('iq');

    final ackReady = alice.awaitLocal('a');
    alice.send('<r xmlns="urn:xmpp:sm:3"/>');
    final ack = await ackReady.timeout(const Duration(seconds: 3));
    expect(int.parse(ack.getAttribute('h')!), greaterThanOrEqualTo(2));
    await alice.close();
  });

  test(
    'XEP-0198 resume: WS drop → new WS → <resume/> replays unacked stanzas',
    () async {
      final alice = await connect(
        email: 'alice@rainbow-stub.local',
        token: aliceToken,
        resource: 'phone',
      );
      alice.send('<enable xmlns="urn:xmpp:sm:3" resume="true"/>');
      final enabled = await alice
          .awaitLocal('enabled')
          .timeout(const Duration(seconds: 3));
      final smid = enabled.getAttribute('id')!;

      // Bob is not yet connected — so this message will be queued for alice's
      // unacked outbound. Instead let's push an event to alice: fastest way is
      // a REST /users/networks POST that triggers a roster push. But actually
      // we need a stanza that arrives at alice. Use a directly-fired presence
      // by having bob (unconnected) get his presence set — that doesn't push
      // to alice. Simplest: send a message from bob to alice, then drop WS
      // before ack.
      final bob = await connect(
        email: 'bob@rainbow-stub.local',
        token: bobToken,
        resource: 'web',
      );
      // Alice should receive bob's message; it'll be added to alice's outbound
      // queue with h=1.
      final firstMsg = alice.awaitLocal('message');
      bob.send(
        '<message id="drop1" to="$aliceId@$_domain" type="chat">'
        '<body>while you were dropping</body></message>',
      );
      await firstMsg.timeout(const Duration(seconds: 3));

      // Drop alice's WS without ack.
      await alice.close();

      // A moment for the server-side park.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Now reconnect as alice; DO NOT bind; instead send <resume/>.
      final aliceUri = Uri.parse('ws://$host:$port/websocket');
      final ch = IOWebSocketChannel.connect(aliceUri, protocols: ['xmpp']);
      await ch.ready;
      final alice2 = _Xmpp(ch);
      await alice2.openStream();
      await alice2.saslPlain(
        email: 'alice@rainbow-stub.local',
        password: aliceToken,
      );
      await alice2.openStream();
      final resumeReady = alice2.stream.firstWhere(
        (e) => e.localName == 'resumed' || e.localName == 'failed',
      );
      // Client thinks it saw 0 stanzas (didn't ack any before drop).
      alice2.send('<resume xmlns="urn:xmpp:sm:3" h="0" previd="$smid"/>');
      final r = await resumeReady.timeout(const Duration(seconds: 3));
      expect(r.localName, 'resumed');

      // Replayed message should arrive.
      final replayed = await alice2
          .awaitLocal('message')
          .timeout(const Duration(seconds: 3));
      expect(replayed.getElement('body')?.innerText, 'while you were dropping');
      await alice2.close();
      await bob.close();
    },
  );

  // -------- XEP-0280 message carbons ----------------------------------------

  test('XEP-0280: no carbons by default → 2nd session of self gets NOTHING '
      'when I send from resource A', () async {
    final aliceA = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final aliceB = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'web',
    );
    var carbonSeen = false;
    final sub = aliceB.stream.listen((e) {
      if (e.localName == 'message' &&
          e.getElement('sent', namespace: 'urn:xmpp:carbons:2') != null) {
        carbonSeen = true;
      }
    });
    aliceA.send(
      '<message id="c1" to="$bobId@$_domain" type="chat">'
      '<body>no-carbon test</body></message>',
    );
    // Give a beat for delivery.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await sub.cancel();
    expect(carbonSeen, isFalse);
    await aliceA.close();
    await aliceB.close();
  });

  test(
    'XEP-0280: after <enable/>, 2nd session of self receives <sent/> carbon',
    () async {
      final aliceA = await connect(
        email: 'alice@rainbow-stub.local',
        token: aliceToken,
        resource: 'phone',
      );
      final aliceB = await connect(
        email: 'alice@rainbow-stub.local',
        token: aliceToken,
        resource: 'web',
      );
      // Enable carbons on B.
      final enableReady = aliceB.stream.firstWhere(
        (e) => e.localName == 'iq' && e.getAttribute('id') == 'cbn1',
      );
      aliceB.send(
        '<iq type="set" id="cbn1">'
        '<enable xmlns="urn:xmpp:carbons:2"/></iq>',
      );
      await enableReady.timeout(const Duration(seconds: 3));

      final carbonReady = aliceB.stream.firstWhere(
        (e) =>
            e.localName == 'message' &&
            e.getElement('sent', namespace: 'urn:xmpp:carbons:2') != null,
      );
      aliceA.send(
        '<message id="c2" to="$bobId@$_domain" type="chat">'
        '<body>please carbon me</body></message>',
      );
      final carbon = await carbonReady.timeout(const Duration(seconds: 3));
      final inner = carbon
          .getElement('sent', namespace: 'urn:xmpp:carbons:2')!
          .getElement('forwarded', namespace: 'urn:xmpp:forward:0')!
          .getElement('message', namespace: 'jabber:client')!;
      expect(inner.getElement('body')?.innerText, 'please carbon me');
      await aliceA.close();
      await aliceB.close();
    },
  );

  // -------- MAM for bubbles + RSM pagination -------------------------------

  test(
    'MAM query on bubble MUC JID returns bubble history with RSM count',
    () async {
      // Alice + bob in a room; pre-populate messages.
      final bubble = app.bubbles.create(ownerId: aliceId, name: 'History Room');
      app.bubbles.addMember(bubble.id, bobId, status: 'accepted');
      final aliceJid = Jid.parse('$aliceId@$_domain');
      for (var i = 1; i <= 5; i++) {
        app.bubbles.insertMessage(
          bubbleId: bubble.id,
          stanzaId: 'b$i',
          from: aliceJid,
          body: 'msg $i',
        );
      }

      final alice = await connect(
        email: 'alice@rainbow-stub.local',
        token: aliceToken,
        resource: 'phone',
      );
      final bodies = <String>[];
      int? countReported;
      final done = Completer<void>();
      late StreamSubscription sub;
      sub = alice.stream.listen((e) {
        if (e.localName == 'message') {
          final inner = e
              .getElement('result', namespace: 'urn:xmpp:mam:2')
              ?.getElement('forwarded', namespace: 'urn:xmpp:forward:0')
              ?.getElement('message', namespace: 'jabber:client');
          final body = inner?.getElement('body')?.innerText;
          if (body != null) bodies.add(body);
        } else if (e.localName == 'iq' && e.getAttribute('id') == 'mam-b1') {
          final count = e
              .getElement('fin', namespace: 'urn:xmpp:mam:2')
              ?.getElement('set', namespace: 'http://jabber.org/protocol/rsm')
              ?.getElement('count')
              ?.innerText;
          if (count != null) countReported = int.parse(count);
          done.complete();
        }
      });
      alice.send(
        '<iq type="set" id="mam-b1">'
        '<query xmlns="urn:xmpp:mam:2">'
        '<x xmlns="jabber:x:data" type="submit">'
        '<field var="with">'
        '<value>${bubble.id}@muc.$_domain</value></field>'
        '</x>'
        '<set xmlns="http://jabber.org/protocol/rsm"><max>3</max></set>'
        '</query></iq>',
      );
      await done.future.timeout(const Duration(seconds: 3));
      await sub.cancel();
      // No anchor + max=3 → the LAST 3 in chronological order.
      expect(bodies, ['msg 3', 'msg 4', 'msg 5']);
      expect(countReported, 5);
      await alice.close();
    },
  );

  test('bubble MAM replay preserves message thread + subject', () async {
    final bubble = app.bubbles.create(ownerId: aliceId, name: 'Topic Room');
    final aliceJid = Jid.parse('$aliceId@$_domain');
    app.bubbles.insertMessage(
      bubbleId: bubble.id,
      stanzaId: 't1',
      from: aliceJid,
      body: 'first post',
      thread: 'topic-abc',
      subject: 'Launch plan',
    );

    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    String? thread;
    String? subject;
    final done = Completer<void>();
    late StreamSubscription sub;
    sub = alice.stream.listen((e) {
      if (e.localName == 'message') {
        final inner = e
            .getElement('result', namespace: 'urn:xmpp:mam:2')
            ?.getElement('forwarded', namespace: 'urn:xmpp:forward:0')
            ?.getElement('message', namespace: 'jabber:client');
        if (inner != null) {
          thread ??= inner.getElement('thread')?.innerText;
          subject ??= inner.getElement('subject')?.innerText;
        }
      } else if (e.localName == 'iq' && e.getAttribute('id') == 'mam-t1') {
        done.complete();
      }
    });
    alice.send(
      '<iq type="set" id="mam-t1">'
      '<query xmlns="urn:xmpp:mam:2">'
      '<x xmlns="jabber:x:data" type="submit">'
      '<field var="with"><value>${bubble.id}@muc.$_domain</value></field>'
      '</x></query></iq>',
    );
    await done.future.timeout(const Duration(seconds: 3));
    await sub.cancel();
    expect(thread, 'topic-abc');
    expect(subject, 'Launch plan');
    await alice.close();
  });

  test('XEP-0313 RSM: <after> anchor returns next page', () async {
    final aliceJid = Jid.parse('$aliceId@$_domain');
    final bobJid = Jid.parse('$bobId@$_domain');
    final inserted = <ChatMessage>[];
    for (var i = 1; i <= 5; i++) {
      inserted.add(
        app.messages.insert(
          from: aliceJid,
          to: bobJid,
          stanzaId: 's$i',
          body: 'p$i',
        ),
      );
    }
    // Anchor after the 2nd persisted item.
    final anchorId = inserted[1].id;

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
        final inner = e
            .getElement('result', namespace: 'urn:xmpp:mam:2')
            ?.getElement('forwarded', namespace: 'urn:xmpp:forward:0')
            ?.getElement('message', namespace: 'jabber:client');
        final body = inner?.getElement('body')?.innerText;
        if (body != null) bodies.add(body);
      } else if (e.localName == 'iq' && e.getAttribute('id') == 'mam-r1') {
        done.complete();
      }
    });
    alice.send(
      '<iq type="set" id="mam-r1">'
      '<query xmlns="urn:xmpp:mam:2">'
      '<x xmlns="jabber:x:data" type="submit">'
      '<field var="with"><value>$bobId@$_domain</value></field>'
      '</x>'
      '<set xmlns="http://jabber.org/protocol/rsm">'
      '<max>2</max><after>$anchorId</after>'
      '</set>'
      '</query></iq>',
    );
    await done.future.timeout(const Duration(seconds: 3));
    await sub.cancel();
    expect(bodies, ['p3', 'p4']);
    await alice.close();
  });

  // -------- XEP-0166 Jingle signaling passthrough -------------------------

  test(
    'session-initiate is routed to the callee and acked to the caller',
    () async {
      final alice = await connect(
        email: 'alice@rainbow-stub.local',
        token: aliceToken,
        resource: 'phone',
      );
      final bob = await connect(
        email: 'bob@rainbow-stub.local',
        token: bobToken,
        resource: 'phone',
      );

      final ackReady = alice.stream.firstWhere(
        (e) => e.localName == 'iq' && e.getAttribute('id') == 'j-init',
      );
      final delivered = Completer<XmlElement>();
      late StreamSubscription sub;
      sub = bob.stream.listen((e) {
        if (e.localName == 'iq' &&
            e.getElement('jingle', namespace: 'urn:xmpp:jingle:1') != null &&
            !delivered.isCompleted) {
          delivered.complete(e);
        }
      });

      alice.send(
        '<iq type="set" id="j-init" to="$bobId@$_domain/phone">'
        '<jingle xmlns="urn:xmpp:jingle:1" action="session-initiate" '
        'sid="sid-1" initiator="$aliceId@$_domain/phone">'
        '<content name="audio" creator="initiator">'
        '<description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio"/>'
        '<transport xmlns="urn:xmpp:jingle:transports:ice-udp:1"/>'
        '</content>'
        '</jingle></iq>',
      );

      final ack = await ackReady.timeout(const Duration(seconds: 3));
      expect(ack.getAttribute('type'), 'result');

      final incoming = await delivered.future.timeout(
        const Duration(seconds: 3),
      );
      final jingle = incoming.getElement(
        'jingle',
        namespace: 'urn:xmpp:jingle:1',
      );
      expect(jingle?.getAttribute('action'), 'session-initiate');
      expect(jingle?.getAttribute('sid'), 'sid-1');
      expect(incoming.getAttribute('from'), startsWith('$aliceId@$_domain'));

      await sub.cancel();
      await alice.close();
      await bob.close();
    },
  );

  test('unknown Jingle action returns feature-not-implemented', () async {
    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );

    final resp = alice.stream.firstWhere(
      (e) => e.localName == 'iq' && e.getAttribute('id') == 'j-bogus',
    );
    alice.send(
      '<iq type="set" id="j-bogus" to="$bobId@$_domain/phone">'
      '<jingle xmlns="urn:xmpp:jingle:1" action="does-not-exist" '
      'sid="sid-x"/>'
      '</iq>',
    );

    final iq = await resp.timeout(const Duration(seconds: 3));
    expect(iq.getAttribute('type'), 'error');
    expect(
      iq
          .getElement('error')
          ?.getElement(
            'feature-not-implemented',
            namespace: 'urn:ietf:params:xml:ns:xmpp-stanzas',
          ),
      isNotNull,
    );
    await alice.close();
  });

  test('M-3 Jingle call round-trip: session-initiate + accept + terminate '
      'flow through the router in sequence', () async {
    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final bob = await connect(
      email: 'bob@rainbow-stub.local',
      token: bobToken,
      resource: 'phone',
    );

    final bobActions = <String>[];
    final aliceActions = <String>[];
    late StreamSubscription bobSub;
    late StreamSubscription aliceSub;
    bobSub = bob.stream.listen((e) {
      if (e.localName != 'iq') return;
      final j = e.getElement('jingle', namespace: 'urn:xmpp:jingle:1');
      if (j != null) bobActions.add(j.getAttribute('action') ?? '');
    });
    aliceSub = alice.stream.listen((e) {
      if (e.localName != 'iq') return;
      final j = e.getElement('jingle', namespace: 'urn:xmpp:jingle:1');
      if (j != null) aliceActions.add(j.getAttribute('action') ?? '');
    });

    // 1. Alice → session-initiate → Bob.
    alice.send(
      '<iq type="set" id="j1" to="$bobId@$_domain/phone">'
      '<jingle xmlns="urn:xmpp:jingle:1" action="session-initiate" '
      'sid="rt-1" initiator="$aliceId@$_domain/phone">'
      '<content name="rtp" creator="initiator">'
      '<rainbow-sdp xmlns="urn:rainbow:jingle:sdp:1">'
      '<![CDATA[v=0]]>'
      '</rainbow-sdp>'
      '</content></jingle></iq>',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 2. Bob → session-accept → Alice.
    bob.send(
      '<iq type="set" id="j2" to="$aliceId@$_domain/phone">'
      '<jingle xmlns="urn:xmpp:jingle:1" action="session-accept" '
      'sid="rt-1" responder="$bobId@$_domain/phone">'
      '<content name="rtp" creator="initiator">'
      '<rainbow-sdp xmlns="urn:rainbow:jingle:sdp:1">'
      '<![CDATA[v=0-answer]]>'
      '</rainbow-sdp>'
      '</content></jingle></iq>',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 3. Alice hangs up → Bob sees session-terminate.
    alice.send(
      '<iq type="set" id="j3" to="$bobId@$_domain/phone">'
      '<jingle xmlns="urn:xmpp:jingle:1" action="session-terminate" '
      'sid="rt-1"><reason><success/></reason></jingle></iq>',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    await bobSub.cancel();
    await aliceSub.cancel();
    expect(bobActions, ['session-initiate', 'session-terminate']);
    expect(aliceActions, ['session-accept']);
    await alice.close();
    await bob.close();
  });
}

class _Xmpp {
  _Xmpp(this._channel) {
    _sub = _channel.stream.listen((raw) {
      final text = raw is List<int> ? utf8.decode(raw) : raw as String;
      try {
        _controller.add(XmlDocument.parse(text).rootElement);
      } on XmlException {
        // ignore
      }
    }, onDone: () => _controller.isClosed ? null : _controller.close());
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
      '<open xmlns="urn:ietf:params:xml:ns:xmpp-framing" to="$_domain" '
      'version="1.0"/>',
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
