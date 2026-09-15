import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rainbow_stub/rainbow_stub.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xml/xml.dart';

const _domain = 'rainbow-stub.local';
const _vcardNs = 'vcard-temp';

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
    final tempDir = Directory.systemTemp.createTempSync('rainbow-stub-vcard');
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

  test('vCard set then get round-trips FN/NICKNAME/EMAIL/PHOTO', () async {
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

    final photoBytes = List<int>.generate(64, (i) => i);
    final photoB64 = base64.encode(photoBytes);

    await alice.iq(
      '<iq type="set" id="vset1">'
      '<vCard xmlns="$_vcardNs">'
      '<FN>Alice In Wonderland</FN>'
      '<NICKNAME>ali</NICKNAME>'
      '<EMAIL><INTERNET/><USERID>ali@rainbow-stub.local</USERID></EMAIL>'
      '<PHOTO><TYPE>image/png</TYPE><BINVAL>$photoB64</BINVAL></PHOTO>'
      '</vCard></iq>',
      'vset1',
    );

    final resp = await bob.iq(
      '<iq type="get" id="vget1" to="$aliceId@$_domain">'
      '<vCard xmlns="$_vcardNs"/></iq>',
      'vget1',
    );
    final card = resp.getElement('vCard', namespace: _vcardNs)!;
    expect(card.getElement('FN')?.innerText, 'Alice In Wonderland');
    expect(card.getElement('NICKNAME')?.innerText, 'ali');
    expect(
      card.getElement('EMAIL')?.getElement('USERID')?.innerText,
      'ali@rainbow-stub.local',
    );
    final photo = card.getElement('PHOTO')!;
    expect(photo.getElement('TYPE')?.innerText, 'image/png');
    expect(photo.getElement('BINVAL')?.innerText, photoB64);

    await alice.close();
    await bob.close();
  });

  test('get with no stored vCard synthesizes FN from the user record',
      () async {
    final bob = await connect(
      email: 'bob@rainbow-stub.local',
      token: bobToken,
      resource: 'web',
    );
    final resp = await bob.iq(
      '<iq type="get" id="vget2" to="$aliceId@$_domain">'
      '<vCard xmlns="$_vcardNs"/></iq>',
      'vget2',
    );
    final card = resp.getElement('vCard', namespace: _vcardNs)!;
    expect(card.getElement('FN')?.innerText, 'Alice Sample');
    expect(card.getElement('PHOTO'), isNull);
    await bob.close();
  });

  test('avatar written via the store surfaces as the vCard PHOTO', () async {
    // Simulates the REST avatar upload path writing to the shared store.
    app.avatars.writeSync(aliceId, Uint8List.fromList([9, 8, 7, 6]), 'image/jpeg');

    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final resp = await alice.iq(
      '<iq type="get" id="vget3"><vCard xmlns="$_vcardNs"/></iq>',
      'vget3',
    );
    final photo = resp
        .getElement('vCard', namespace: _vcardNs)!
        .getElement('PHOTO')!;
    expect(photo.getElement('TYPE')?.innerText, 'image/jpeg');
    expect(
      photo.getElement('BINVAL')?.innerText,
      base64.encode([9, 8, 7, 6]),
    );
    await alice.close();
  });

  test('anonymous guest cannot set a vCard', () async {
    // Reboot with anonymous enabled.
    await server.close(force: true);
    app.db.close();
    final tempDir = Directory.systemTemp.createTempSync('rainbow-stub-vc-anon');
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
    server = await shelf_io.serve(app.buildHandler(), '127.0.0.1', 0);
    host = server.address.host;
    port = server.port;

    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://$host:$port/websocket'),
      protocols: ['xmpp'],
    );
    await channel.ready;
    final guest = _Xmpp(channel);
    await guest.openStream();
    await guest.saslAnonymous();
    await guest.openStream();
    await guest.bind('guest');

    final resp = await guest.iq(
      '<iq type="set" id="vset-anon">'
      '<vCard xmlns="$_vcardNs"><FN>Nope</FN></vCard></iq>',
      'vset-anon',
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
