import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xml/xml.dart';

import '../auth/auth_service.dart';
import '../bubbles/bubble_repository.dart';
import '../messages/message_repository.dart';
import '../messages/reaction_repository.dart';
import '../push/push_token_repository.dart';
import '../sip/sip_gateway.dart';
import '../users/presence_repository.dart';
import '../users/roster_repository.dart';
import '../users/user_repository.dart';
import 'jid.dart';
import 'router.dart';

final _log = Logger('xmpp.session');

/// Namespaces used by RFC 7395 XMPP-over-WebSocket + SASL + binding.
class Ns {
  static const framing = 'urn:ietf:params:xml:ns:xmpp-framing';
  static const streams = 'http://etherx.jabber.org/streams';
  static const sasl = 'urn:ietf:params:xml:ns:xmpp-sasl';
  static const bind = 'urn:ietf:params:xml:ns:xmpp-bind';
  static const client = 'jabber:client';
  static const mam2 = 'urn:xmpp:mam:2';
  static const forward = 'urn:xmpp:forward:0';
  static const delay = 'urn:xmpp:delay';
  static const chatStates = 'http://jabber.org/protocol/chatstates';
  static const mucPrefix = 'muc.';
  static const ping = 'urn:xmpp:ping';
  static const roster = 'jabber:iq:roster';
  static const discoInfo = 'http://jabber.org/protocol/disco#info';
  static const discoItems = 'http://jabber.org/protocol/disco#items';
  static const receipts = 'urn:xmpp:receipts';
  static const chatMarkers = 'urn:xmpp:chat-markers:0';
  static const reactions = 'urn:xmpp:reactions:0';
  static const messageRetract = 'urn:xmpp:message-retract:1';
  static const muc = 'http://jabber.org/protocol/muc';
  static const mucUser = 'http://jabber.org/protocol/muc#user';
  static const sm3 = 'urn:xmpp:sm:3';
  static const carbons2 = 'urn:xmpp:carbons:2';
  static const rsm = 'http://jabber.org/protocol/rsm';
  static const jingle = 'urn:xmpp:jingle:1';
  static const mucCall = 'urn:rainbow:muc-call:1';
  static const lastActivity = 'jabber:iq:last';
}

/// Server-wide registry of resumable Stream Management sessions.
/// Sessions park here for [holdWindow] after WS disconnect; a subsequent
/// `<resume/>` from any new WS re-attaches to the parked session.
class SmRegistry {
  SmRegistry({
    this.holdWindow = const Duration(seconds: 120),
    this.maxPerUser = 2,
  });

  final Duration holdWindow;

  /// Cap on parked sessions per user — prevents one client from consuming
  /// unbounded server memory by opening and dropping many resumable
  /// sessions.
  final int maxPerUser;

  final _held = <String, _HeldSession>{};

  void park(String smid, XmppWsSession session) {
    // Evict oldest for this user if over cap.
    final userSmids =
        _held.entries.where((e) => e.value.userId == session.userId).toList()
          ..sort((a, b) => a.value.parkedAt.compareTo(b.value.parkedAt));
    while (userSmids.length >= maxPerUser) {
      final victim = userSmids.removeAt(0);
      _held.remove(victim.key);
      victim.value.timer.cancel();
      victim.value.session.finalize();
    }
    final held = _HeldSession(session);
    held.timer = Timer(holdWindow, () {
      _held.remove(smid);
      session.finalize();
    });
    _held[smid] = held;
  }

  XmppWsSession? claim(String smid) {
    final h = _held.remove(smid);
    h?.timer.cancel();
    return h?.session;
  }

  /// Enumerate all currently-parked sessions (for graceful shutdown).
  Iterable<XmppWsSession> allSessions() =>
      _held.values.map((h) => h.session).toList(growable: false);

  int get heldCount => _held.length;
}

class _HeldSession {
  _HeldSession(this.session) : parkedAt = DateTime.now();
  final XmppWsSession session;
  final DateTime parkedAt;
  String get userId => session.userId;
  late Timer timer;
}

enum _State { streamOpened, authenticated, bound, closed }

/// Hardening tunables — keep together so they're easy to review.
class XmppLimits {
  const XmppLimits({
    this.maxFrameBytes = 128 * 1024,
    this.maxOutboundQueue = 500,
    this.maxSessionsPerUser = 8,
    this.maxSaslFailures = 3,
    this.maxHeldPerUser = 2,
    this.smKeepaliveIdle = const Duration(seconds: 30),
    this.smAckDeadline = const Duration(seconds: 60),
  });

  final int maxFrameBytes;
  final int maxOutboundQueue;
  final int maxSessionsPerUser;
  final int maxSaslFailures;
  final int maxHeldPerUser;
  final Duration smKeepaliveIdle;
  final Duration smAckDeadline;
}

class XmppWsSession implements XmppSession {
  XmppWsSession({
    required WebSocketChannel channel,
    required this.domain,
    required this.auth,
    required this.users,
    required this.presence,
    required this.messages,
    required this.reactions,
    required this.bubbles,
    required this.roster,
    required this.router,
    required this.smRegistry,
    required this.pushTokens,
    this.sipGateway,
    this.limits = const XmppLimits(),
  }) : _channel = channel;

  WebSocketChannel _channel;
  final String domain;
  final AuthService auth;
  final UserRepository users;
  final PresenceRepository presence;
  final MessageRepository messages;
  final ReactionRepository reactions;
  final BubbleRepository bubbles;
  final RosterRepository roster;
  final StanzaRouter router;
  final SmRegistry smRegistry;
  final PushTokenRepository pushTokens;
  final SipGateway? sipGateway;
  final XmppLimits limits;

  _State _state = _State.streamOpened;
  String _resource = 'stub';
  Jid _jid = const Jid(local: '', domain: '');
  String _userId = '';
  int _saslFailures = 0;

  // XEP-0198 stream management
  bool _smEnabled = false;
  bool _smResumable = false;
  String _smid = '';
  int _hIn = 0;
  int _hOut = 0;
  final _outbound = <_OutboundStanza>[];
  Timer? _keepaliveTimer;
  Timer? _ackDeadlineTimer;
  DateTime _lastRxAt = DateTime.now();

  // XEP-0280 carbons
  bool _carbonsEnabled = false;

  bool _channelActive = true;

  @override
  Jid get jid => _jid;

  @override
  String get userId => _userId;

  @override
  void send(String stanza) {
    if (_state == _State.closed) return;
    if (_smEnabled) {
      _hOut++;
      _outbound.add(_OutboundStanza(_hOut, stanza));
      if (_outbound.length > limits.maxOutboundQueue) {
        _log.warning(
          'SM outbound queue overflow — closing '
          '(jid=$_jid queue=${_outbound.length})',
        );
        // Overflow → force non-resumable close so the client resyncs cleanly.
        _smResumable = false;
        _channelActive = false;
        unawaited(finalize());
        return;
      }
    }
    _log.fine('<- $stanza');
    if (_channelActive) {
      try {
        _channel.sink.add(stanza);
      } catch (_) {
        _channelActive = false;
      }
    }
  }

  Future<void> run() async {
    try {
      await for (final frame in _channel.stream) {
        final text = frame is List<int> ? utf8.decode(frame) : frame as String;
        _log.fine('-> $text');
        await _handleFrame(text);
        if (_state == _State.closed) break;
      }
    } catch (e, st) {
      _log.warning('stream error', e, st);
    } finally {
      _channelActive = false;
      await _onChannelDropped();
    }
  }

  Future<void> _onChannelDropped() async {
    if (_state == _State.closed) return;
    _stopKeepalive();
    if (_smResumable && _state == _State.bound) {
      _log.info('parking session for resume smid=$_smid');
      router.unregister(this);
      smRegistry.park(_smid, this);
      return;
    }
    await finalize();
  }

  /// Fully close the session (called on non-resumable disconnect OR after
  /// the resume window expires).
  Future<void> finalize() async {
    if (_state == _State.closed) return;
    _state = _State.closed;
    _stopKeepalive();
    router.unregister(this);
    if (_jid.local.isNotEmpty) {
      presence.set(_userId, 'offline');
      _fanOutPresenceAvailability(unavailable: true);
    }
    try {
      await _channel.sink.close();
    } catch (_) {}
  }

  Future<void> _close() async {
    if (_state == _State.closed) return;
    _state = _State.closed;
    router.unregister(this);
    if (_jid.local.isNotEmpty) {
      presence.set(_userId, 'offline');
      _fanOutPresenceAvailability(unavailable: true);
    }
    try {
      await _channel.sink.close();
    } catch (_) {}
  }

  Future<void> _handleFrame(String text) async {
    _lastRxAt = DateTime.now();
    if (text.length > limits.maxFrameBytes) {
      _log.warning(
        'oversize frame ${text.length}B > ${limits.maxFrameBytes}B — closing',
      );
      _smResumable = false;
      await finalize();
      return;
    }
    // Belt-and-braces XXE / billion-laughs guard. The `xml` package does not
    // resolve external entities, but rejecting DOCTYPEs outright prevents any
    // future toolchain from accidentally enabling entity expansion. Zero cost
    // to a legit XMPP client — no XMPP stanza starts with `<!`.
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('<!DOCTYPE') || trimmed.startsWith('<!ENTITY')) {
      _log.warning('rejecting DOCTYPE/ENTITY frame — closing');
      _smResumable = false;
      await finalize();
      return;
    }
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(text);
    } on XmlException {
      _log.warning('malformed XML: $text');
      return;
    }
    final el = doc.rootElement;
    final ns = el.name.namespaceUri;

    // XEP-0198 control stanzas (not counted).
    if (ns == Ns.sm3) {
      switch (el.localName) {
        case 'enable':
          _handleSmEnable(el);
        case 'resume':
          _handleSmResume(el);
        case 'r':
          _sendSmAck();
        case 'a':
          _handleSmAck(el);
      }
      return;
    }

    switch (el.localName) {
      case 'open':
        _handleOpen(el);
      case 'close':
        await _close();
      case 'auth':
        _handleAuth(el);
      case 'iq':
        if (_smEnabled) _hIn++;
        _handleIq(el);
      case 'message':
        if (_smEnabled) _hIn++;
        _handleMessage(el);
      case 'presence':
        if (_smEnabled) _hIn++;
        _handlePresence(el);
      default:
        _log.warning('unknown stanza: ${el.localName}');
    }
  }

  void _sendSmAck() {
    // Never counted, never queued for retransmit.
    if (_channelActive) {
      try {
        _channel.sink.add('<a xmlns="${Ns.sm3}" h="$_hIn"/>');
      } catch (_) {
        _channelActive = false;
      }
    }
  }

  void _handleSmAck(XmlElement el) {
    final h = int.tryParse(el.getAttribute('h') ?? '');
    if (h == null) return;
    _outbound.removeWhere((o) => o.h <= h);
    _ackDeadlineTimer?.cancel();
  }

  void _handleSmEnable(XmlElement el) {
    if (_state != _State.bound) return;
    _smEnabled = true;
    _smResumable =
        el.getAttribute('resume') == 'true' || el.getAttribute('resume') == '1';
    _smid = _newSmId();
    final resumeAttr = _smResumable ? ' resume="true"' : '';
    final rawSend =
        '<enabled xmlns="${Ns.sm3}" id="${_esc(_smid)}"'
        '$resumeAttr max="120"/>';
    if (_channelActive) {
      try {
        _channel.sink.add(rawSend);
      } catch (_) {
        _channelActive = false;
      }
    }
    _startKeepalive();
  }

  void _startKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer.periodic(limits.smKeepaliveIdle, (_) {
      if (_state != _State.bound || !_channelActive) return;
      final idle = DateTime.now().difference(_lastRxAt);
      if (idle < limits.smKeepaliveIdle) return;
      // Fire <r/> and start ack deadline.
      try {
        _channel.sink.add('<r xmlns="${Ns.sm3}"/>');
      } catch (_) {
        _channelActive = false;
        return;
      }
      _ackDeadlineTimer?.cancel();
      _ackDeadlineTimer = Timer(limits.smAckDeadline, () {
        if (_state != _State.bound) return;
        _log.warning('SM ack deadline expired — dropping channel');
        _channelActive = false;
        unawaited(_onChannelDropped());
      });
    });
  }

  void _stopKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    _ackDeadlineTimer?.cancel();
    _ackDeadlineTimer = null;
  }

  void _handleSmResume(XmlElement el) {
    final previd = el.getAttribute('previd') ?? '';
    final clientH = int.tryParse(el.getAttribute('h') ?? '') ?? 0;
    final parked = smRegistry.claim(previd);
    if (parked == null || _state != _State.authenticated) {
      if (_channelActive) {
        try {
          _channel.sink.add(
            '<failed xmlns="${Ns.sm3}" h="0" previd="${_esc(previd)}">'
            '<item-not-found xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>'
            '</failed>',
          );
        } catch (_) {
          _channelActive = false;
        }
      }
      return;
    }
    // Only the same user can resume their own SM session.
    if (parked._userId != _userId) {
      smRegistry.park(previd, parked);
      if (_channelActive) {
        try {
          _channel.sink.add(
            '<failed xmlns="${Ns.sm3}" h="0" previd="${_esc(previd)}">'
            '<not-authorized xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>'
            '</failed>',
          );
        } catch (_) {
          _channelActive = false;
        }
      }
      return;
    }

    // Adopt parked state onto this fresh session.
    _resource = parked._resource;
    _jid = parked._jid;
    _smid = parked._smid;
    _smEnabled = parked._smEnabled;
    _smResumable = parked._smResumable;
    _hIn = parked._hIn;
    _hOut = parked._hOut;
    _outbound
      ..clear()
      ..addAll(parked._outbound);
    _carbonsEnabled = parked._carbonsEnabled;
    _state = _State.bound;
    router.register(this);

    // Drop stanzas the client already saw.
    _outbound.removeWhere((o) => o.h <= clientH);
    try {
      _channel.sink.add(
        '<resumed xmlns="${Ns.sm3}" h="$_hIn" previd="${_esc(previd)}"/>',
      );
      for (final o in _outbound.toList()) {
        _channel.sink.add(o.stanza);
      }
    } catch (_) {
      _channelActive = false;
    }
    // Parked session's own finalize is a no-op now (state stays 'bound' but
    // its channel is dead) — just mark it closed without unregistering us.
    parked._forceClosedWithoutUnregister();
  }

  /// Marks a parked (dead-channel) session as closed WITHOUT touching the
  /// router. Used when its state has been transferred to a resuming session.
  void _forceClosedWithoutUnregister() {
    _state = _State.closed;
  }

  String _newSmId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(16) +
      _userId.substring(0, _userId.length.clamp(0, 4));

  void _handleOpen(XmlElement _) {
    // Reply <open> then advertise features appropriate to current state.
    send(
      '<open xmlns="${Ns.framing}" from="$domain" version="1.0" '
      'id="${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}"/>',
    );
    if (_state == _State.streamOpened) {
      send(
        '<stream:features xmlns:stream="${Ns.streams}">'
        '<mechanisms xmlns="${Ns.sasl}"><mechanism>PLAIN</mechanism></mechanisms>'
        '</stream:features>',
      );
    } else if (_state == _State.authenticated) {
      send(
        '<stream:features xmlns:stream="${Ns.streams}">'
        '<bind xmlns="${Ns.bind}"/>'
        '<sm xmlns="${Ns.sm3}"/>'
        '</stream:features>',
      );
    } else if (_state == _State.bound) {
      send(
        '<stream:features xmlns:stream="${Ns.streams}">'
        '<sm xmlns="${Ns.sm3}"/>'
        '</stream:features>',
      );
    }
  }

  void _handleAuth(XmlElement el) {
    if (el.getAttribute('mechanism') != 'PLAIN') {
      _saslFailure('<invalid-mechanism/>');
      return;
    }
    final raw = base64.decode(el.innerText.trim());
    final parts = String.fromCharCodes(raw).split('\u0000');
    if (parts.length != 3) {
      _saslFailure('<malformed-request/>');
      return;
    }
    final email = parts[1];
    final token = parts[2];
    final u = users.findByEmail(email);
    if (u == null) {
      _saslFailure('<not-authorized/>');
      return;
    }
    try {
      final me = auth.authenticateBearer('Bearer $token');
      if (me.id != u.id) throw StateError('token owner mismatch');
    } catch (_) {
      if (!users.verifyPassword(u, token)) {
        _saslFailure('<not-authorized/>');
        return;
      }
    }
    _userId = u.id;
    _jid = Jid(local: u.id, domain: domain);
    _state = _State.authenticated;
    _saslFailures = 0;
    send('<success xmlns="${Ns.sasl}"/>');
  }

  void _saslFailure(String reasonElement) {
    _saslFailures++;
    send('<failure xmlns="${Ns.sasl}">$reasonElement</failure>');
    if (_saslFailures >= limits.maxSaslFailures) {
      _log.warning('too many SASL failures — closing stream');
      unawaited(finalize());
    }
  }

  void _handleIq(XmlElement el) {
    final id = el.getAttribute('id') ?? '';
    final type = el.getAttribute('type');
    // Resource binding.
    final bindEl = el.getElement('bind', namespace: Ns.bind);
    if (bindEl != null && type == 'set') {
      if (router.sessionsOf(_userId).length >= limits.maxSessionsPerUser) {
        send(
          '<iq type="error" id="${_esc(id)}">'
          '<error type="cancel" code="409">'
          '<policy-violation xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>'
          '<text xmlns="urn:ietf:params:xml:ns:xmpp-stanzas">'
          'Too many sessions for this account</text>'
          '</error></iq>',
        );
        _log.warning(
          'session cap exceeded for $_userId (${limits.maxSessionsPerUser})',
        );
        unawaited(finalize());
        return;
      }
      final res = bindEl.getElement('resource')?.innerText.trim();
      if (res != null && res.isNotEmpty) _resource = res;
      _jid = Jid(local: _userId, domain: domain, resource: _resource);
      _state = _State.bound;
      router.register(this);
      send(
        '<iq type="result" id="${_esc(id)}">'
        '<bind xmlns="${Ns.bind}"><jid>${_esc(_jid.toString())}</jid></bind>'
        '</iq>',
      );
      return;
    }
    // XEP-0199 ping.
    if (el.getElement('ping', namespace: Ns.ping) != null && type == 'get') {
      send('<iq type="result" id="${_esc(id)}" from="${_esc(domain)}"/>');
      return;
    }
    // XEP-0030 disco#info.
    final disco = el.getElement('query', namespace: Ns.discoInfo);
    if (disco != null && type == 'get') {
      _replyDiscoInfo(id);
      return;
    }
    // RFC 6121 roster.
    final rosterEl = el.getElement('query', namespace: Ns.roster);
    if (rosterEl != null && type == 'get') {
      _replyRosterGet(id);
      return;
    }
    // XEP-0280 carbons enable / disable.
    final carbonsEnable = el.getElement('enable', namespace: Ns.carbons2);
    final carbonsDisable = el.getElement('disable', namespace: Ns.carbons2);
    if ((carbonsEnable != null || carbonsDisable != null) && type == 'set') {
      _carbonsEnabled = carbonsEnable != null;
      send('<iq type="result" id="${_esc(id)}"/>');
      return;
    }
    // MAM query.
    final mamEl = el.getElement('query', namespace: Ns.mam2);
    if (mamEl != null && type == 'set') {
      _handleMamQuery(id, mamEl);
      return;
    }
    // XEP-0012 Last Activity — the server answers on behalf of the
    // target user from the presence record's timestamp.
    final lastEl = el.getElement('query', namespace: Ns.lastActivity);
    if (lastEl != null && type == 'get') {
      _replyLastActivity(id, el.getAttribute('to'));
      return;
    }
    // XEP-0166 Jingle signaling — routed opaquely to the peer.
    final jingleEl = el.getElement('jingle', namespace: Ns.jingle);
    if (jingleEl != null && type == 'set') {
      _handleJingle(id, el, jingleEl);
      return;
    }
    // Unknown IQ — RFC 6120 §8.2.3: a get/set the server doesn't
    // understand MUST be answered with <service-unavailable/>, not an
    // empty result.
    if (type == 'get' || type == 'set') {
      final fromAttr = el.getAttribute('from');
      send(
        '<iq type="error" id="${_esc(id)}"'
        '${fromAttr != null ? ' to="${_esc(fromAttr)}"' : ''}>'
        '<error type="cancel">'
        '<service-unavailable xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>'
        '</error></iq>',
      );
    }
  }

  /// XEP-0166 §7 signaling routing. We don't understand the payload —
  /// session-initiate, session-accept, session-terminate, transport-
  /// info, content-add, etc. all pass through opaquely to the callee.
  /// Unknown actions return a `feature-not-implemented` error so
  /// callers can distinguish "server doesn't grok this" from "peer
  /// hasn't responded yet".
  void _handleJingle(String iqId, XmlElement iq, XmlElement jingle) {
    const knownActions = {
      'session-initiate',
      'session-accept',
      'session-terminate',
      'session-info',
      'transport-info',
      'transport-replace',
      'transport-accept',
      'transport-reject',
      'content-add',
      'content-accept',
      'content-modify',
      'content-reject',
      'content-remove',
      'description-info',
      'security-info',
    };
    final action = jingle.getAttribute('action') ?? '';
    if (!knownActions.contains(action)) {
      send(
        '<iq type="error" id="${_esc(iqId)}">'
        '<error type="cancel" code="501">'
        '<feature-not-implemented xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>'
        '<text xmlns="urn:ietf:params:xml:ns:xmpp-stanzas">'
        'Unknown Jingle action: ${_esc(action)}</text>'
        '</error></iq>',
      );
      return;
    }
    final toAttr = iq.getAttribute('to');
    if (toAttr == null) {
      send(
        '<iq type="error" id="${_esc(iqId)}">'
        '<error type="modify" code="400">'
        '<bad-request xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>'
        '</error></iq>',
      );
      return;
    }
    final to = Jid.parse(toAttr);
    // Ack the sender immediately so their iq bookkeeping unwinds; the
    // peer's session-accept / -terminate arrives as a separate iq.
    send('<iq type="result" id="${_esc(iqId)}"/>');

    // SIP-domain callee — hand the Jingle payload to the bridge.
    final gw = sipGateway;
    if (gw != null && to.domain == gw.sipDomain) {
      unawaited(gw.onJingle(callerJid: _jid, calleeJid: to, jingle: jingle));
      return;
    }

    final forwarded = _rewriteFrom(iq);
    router.fanOut(to.local, forwarded);
  }

  void _replyDiscoInfo(String id) {
    const feats = [
      Ns.ping,
      Ns.roster,
      Ns.mam2,
      Ns.chatStates,
      Ns.receipts,
      Ns.chatMarkers,
      Ns.discoInfo,
      Ns.discoItems,
      Ns.muc,
      Ns.sm3,
      Ns.carbons2,
      Ns.rsm,
      Ns.jingle,
    ];
    final buf = StringBuffer(
      '<iq type="result" id="${_esc(id)}" from="${_esc(domain)}" '
      'to="${_esc(_jid.toString())}">'
      '<query xmlns="${Ns.discoInfo}">'
      '<identity category="server" type="im" name="rainbow-stub"/>',
    );
    for (final f in feats) {
      buf.write('<feature var="${_esc(f)}"/>');
    }
    buf.write('</query></iq>');
    send(buf.toString());
  }

  void _replyRosterGet(String id) {
    final entries = roster.listFor(_userId, limit: 500);
    final buf = StringBuffer(
      '<iq type="result" id="${_esc(id)}" to="${_esc(_jid.toString())}">'
      '<query xmlns="${Ns.roster}">',
    );
    for (final e in entries) {
      final contactJid = '${e.contact.id}@$domain';
      final name = _esc(e.contact.displayName);
      buf.write(
        '<item jid="${_esc(contactJid)}" name="$name" '
        'subscription="both"/>',
      );
    }
    buf.write('</query></iq>');
    send(buf.toString());
  }

  void _handleMamQuery(String queryId, XmlElement query) {
    final withVal = _mamField(query, 'with');
    final rsm = query.getElement('set', namespace: Ns.rsm);
    var max = int.tryParse(rsm?.getElement('max')?.innerText ?? '') ?? 50;
    if (max > 200) max = 200;
    if (max < 1) max = 1;

    if (withVal == null) {
      // No `with` filter — return the newest [max] archived 1:1
      // stanzas across all peers, used by the client's Recent-tab
      // bootstrap on sign-in.
      final slice = messages.mamSliceForUser(_jid, max: max);
      for (final m in slice.page) {
        send(_wrapForMam(queryId, m));
      }
      send(
        _mamFin(
          queryId,
          slice.page,
          total: slice.total,
          complete: slice.page.length < max,
        ),
      );
      _replayReactionsFor1To1(slice.page);
      return;
    }
    final peer = Jid.parse(withVal);
    final beforeId = rsm?.getElement('before')?.innerText;
    final afterId = rsm?.getElement('after')?.innerText;

    if (peer.domain.startsWith(Ns.mucPrefix)) {
      final myMember = bubbles.memberOf(peer.local, _userId);
      if (myMember == null || myMember.status != 'accepted') {
        _sendMamForbidden(queryId);
        return;
      }
      final slice = bubbles.mamSlice(
        peer.local,
        max: max,
        beforeId: beforeId,
        afterId: afterId,
      );
      for (final m in slice.page) {
        send(_wrapBubbleForMam(queryId, m));
      }
      send(
        _mamFin(
          queryId,
          slice.page,
          total: slice.total,
          complete: slice.page.length < max,
        ),
      );
      _replayReactionsForBubble(peer, slice.page);
      return;
    }

    // 1:1 MAM: the underlying SQL filter uses a canonical conversation ID
    // built from `min(_jid.bare, peer.bare)` so the caller can only see
    // conversations they were a party to — no separate auth check needed.
    final slice = messages.mamSlice(
      _jid,
      peer,
      max: max,
      beforeId: beforeId,
      afterId: afterId,
    );
    for (final m in slice.page) {
      send(_wrapForMam(queryId, m));
    }
    send(
      _mamFin(
        queryId,
        slice.page,
        total: slice.total,
        complete: slice.page.length < max,
      ),
    );
    _replayReactionsFor1To1(slice.page);
  }

  String _mamFin(
    String queryId,
    List<Object> page, {
    required int total,
    bool complete = true,
  }) {
    String? first;
    String? last;
    if (page.isNotEmpty) {
      first = page.first is ChatMessage
          ? (page.first as ChatMessage).id
          : (page.first as BubbleMessage).id;
      last = page.last is ChatMessage
          ? (page.last as ChatMessage).id
          : (page.last as BubbleMessage).id;
    }
    final buf = StringBuffer(
      '<iq type="result" id="${_esc(queryId)}">'
      '<fin xmlns="${Ns.mam2}" complete="${complete ? 'true' : 'false'}">'
      '<set xmlns="${Ns.rsm}">',
    );
    if (first != null) buf.write('<first>${_esc(first)}</first>');
    if (last != null) buf.write('<last>${_esc(last)}</last>');
    buf.write('<count>$total</count>');
    buf.write('</set></fin></iq>');
    return buf.toString();
  }

  void _sendMamForbidden(String queryId) {
    send(
      '<iq type="error" id="${_esc(queryId)}">'
      '<error type="cancel" code="403">'
      '<forbidden xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>'
      '</error></iq>',
    );
  }

  String? _mamField(XmlElement query, String name) {
    for (final f in query.findAllElements('field')) {
      if (f.getAttribute('var') == name) {
        return f.getElement('value')?.innerText.trim();
      }
    }
    return null;
  }

  String _wrapForMam(String queryId, ChatMessage m) {
    final inner =
        '<message xmlns="${Ns.client}" from="${_esc(m.from.toString())}" '
        'to="${_esc(m.to.toString())}" type="chat" id="${_esc(m.stanzaId)}">'
        '<body>${_esc(m.body)}</body>'
        '</message>';
    return '<message to="${_esc(_jid.toString())}">'
        '<result xmlns="${Ns.mam2}" queryid="${_esc(queryId)}" id="${_esc(m.id)}">'
        '<forwarded xmlns="${Ns.forward}">'
        '<delay xmlns="${Ns.delay}" stamp="${m.sentAt.toUtc().toIso8601String()}"/>'
        '$inner'
        '</forwarded>'
        '</result>'
        '</message>';
  }

  String _wrapBubbleForMam(String queryId, BubbleMessage m) {
    final roomJid = '${m.bubbleId}@${Ns.mucPrefix}$domain';
    final inner =
        '<message xmlns="${Ns.client}" from="${_esc('$roomJid/${m.from.local}')}" '
        'to="${_esc(roomJid)}" type="groupchat" id="${_esc(m.stanzaId)}">'
        '<body>${_esc(m.body)}</body>'
        '</message>';
    return '<message to="${_esc(_jid.toString())}">'
        '<result xmlns="${Ns.mam2}" queryid="${_esc(queryId)}" id="${_esc(m.id)}">'
        '<forwarded xmlns="${Ns.forward}">'
        '<delay xmlns="${Ns.delay}" stamp="${m.sentAt.toUtc().toIso8601String()}"/>'
        '$inner'
        '</forwarded>'
        '</result>'
        '</message>';
  }

  /// Persists the reaction snapshot from a `<message><reactions>…` stanza.
  /// Called BEFORE forwarding so the archive is authoritative even if the
  /// recipient is offline.
  void _persistReactions(XmlElement message) {
    final reactionsEl = message.getElement('reactions');
    if (reactionsEl == null) return;
    final targetId = reactionsEl.getAttribute('id');
    if (targetId == null || targetId.isEmpty) return;
    final emojis = reactionsEl.children
        .whereType<XmlElement>()
        .where((c) => c.localName == 'reaction')
        .map((c) => c.innerText)
        .where((s) => s.isNotEmpty)
        .toList();
    reactions.upsert(
      targetStanzaId: targetId,
      fromUserId: _userId,
      emojis: emojis,
    );
  }

  /// After 1:1 MAM history is delivered, replay every persisted reaction
  /// on those messages as a live `<message><reactions>` stanza so the
  /// client's normal reactions listener updates the corresponding bubble.
  void _replayReactionsFor1To1(List<ChatMessage> page) {
    for (final m in page) {
      final byUser = reactions.findForMessage(m.stanzaId);
      for (final entry in byUser.entries) {
        final fromJid = '${entry.key}@$domain';
        send(
          _buildReactionsStanza(
            fromJid: fromJid,
            targetStanzaId: m.stanzaId,
            emojis: entry.value,
            type: 'chat',
          ),
        );
      }
    }
  }

  void _replayReactionsForBubble(Jid room, List<BubbleMessage> page) {
    final roomJid = room.toString();
    for (final m in page) {
      final byUser = reactions.findForMessage(m.stanzaId);
      for (final entry in byUser.entries) {
        // MUC nicks are just the user's local part in this stub.
        send(
          _buildReactionsStanza(
            fromJid: '$roomJid/${entry.key}',
            targetStanzaId: m.stanzaId,
            emojis: entry.value,
            type: 'groupchat',
          ),
        );
      }
    }
  }

  String _buildReactionsStanza({
    required String fromJid,
    required String targetStanzaId,
    required List<String> emojis,
    required String type,
  }) {
    final buf = StringBuffer()
      ..write(
        '<message xmlns="${Ns.client}" from="${_esc(fromJid)}" '
        'to="${_esc(_jid.toString())}" type="$type">',
      )
      ..write(
        '<reactions xmlns="${Ns.reactions}" id="${_esc(targetStanzaId)}">',
      );
    for (final e in emojis) {
      buf.write('<reaction>${_esc(e)}</reaction>');
    }
    buf.write('</reactions></message>');
    return buf.toString();
  }

  void _handleMessage(XmlElement el) {
    if (_state != _State.bound) return;
    final toAttr = el.getAttribute('to');
    if (toAttr == null) return;
    final to = Jid.parse(toAttr);
    final type = el.getAttribute('type');

    final body = el.getElement('body')?.innerText;
    final chatState = el.children
        .whereType<XmlElement>()
        .where((e) => e.name.namespaceUri == Ns.chatStates)
        .firstOrNull;
    final hasReceipt = el.children.whereType<XmlElement>().any(
      (e) => e.name.namespaceUri == Ns.receipts,
    );
    final hasMarker = el.children.whereType<XmlElement>().any(
      (e) => e.name.namespaceUri == Ns.chatMarkers,
    );
    final hasReactions = el.children.whereType<XmlElement>().any(
      (e) => e.name.namespaceUri == Ns.reactions,
    );
    final retractEl = el.children.whereType<XmlElement>().firstWhere(
      (e) =>
          e.name.namespaceUri == Ns.messageRetract && e.localName == 'retract',
      orElse: () => XmlElement(XmlName('none')),
    );
    final hasRetract = retractEl.name.local != 'none';

    // Group chat (bubble). `to` is <bubbleId>@muc.<domain>.
    if (type == 'groupchat' || to.domain.startsWith(Ns.mucPrefix)) {
      if (hasRetract) {
        _handleGroupRetract(to, retractEl);
        return;
      }
      _handleGroupChat(el, to, body);
      return;
    }

    // XEP-0424 retract on a 1:1 message.
    if (hasRetract && body == null) {
      _handle1To1Retract(to, retractEl);
      return;
    }

    // Chat-state / receipt / marker / reactions only — forward without
    // persisting the surrounding message. For reactions we DO persist an
    // out-of-band snapshot so MAM can replay them to offline recipients.
    if (body == null &&
        (chatState != null || hasReceipt || hasMarker || hasReactions)) {
      if (hasReactions) _persistReactions(el);
      final forwarded = _rewriteFrom(el);
      router.fanOut(to.local, forwarded);
      return;
    }
    if (body == null) return;

    final stanzaId =
        el.getAttribute('id') ??
        DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final saved = messages.insert(
      from: _jid,
      to: to,
      stanzaId: stanzaId,
      body: body,
    );
    final forwarded = _rewriteFrom(el, id: saved.stanzaId);

    // SIP-domain recipient — bridge to SIP MESSAGE instead of XMPP fan-out.
    final gw = sipGateway;
    if (gw != null && to.domain == gw.sipDomain) {
      unawaited(
        gw.sendText(from: _jid, to: to, body: body, stanzaId: saved.stanzaId),
      );
      for (final s in router.sessionsOf(_userId)) {
        if (identical(s, this)) continue;
        if (s is XmppWsSession && s._carbonsEnabled) {
          s.send(_wrapSentCarbon(forwarded));
        }
      }
      return;
    }

    // Note: sender-side ack is now delivered via XEP-0198 stream
    // management (`<a h="…"/>`) — the counter increments naturally
    // when the outgoing echo/forward path pushes stanzas.
    final delivered = router.fanOut(to.local, forwarded);
    // If the recipient has NO active XMPP session, log every push
    // token we'd notify. In production this is where FCM/APNs would
    // be called; for the stub it's just an INFO line the test can
    // scrape.
    if (delivered == 0) {
      final tokens = pushTokens.findForUser(to.local);
      for (final t in tokens) {
        _log.info(
          'would-push user=${to.local} '
          'platform=${t.platform} token=${t.token} from=$_userId',
        );
      }
    }
    // XEP-0280 sent-carbon to my other sessions that opted in.
    for (final s in router.sessionsOf(_userId)) {
      if (identical(s, this)) continue;
      if (s is XmppWsSession && s._carbonsEnabled) {
        s.send(_wrapSentCarbon(forwarded));
      }
    }
  }

  /// XEP-0424 retract on a 1:1 conversation — deletes the archived row
  /// and forwards a synthetic `<message><retract/></message>` to the
  /// peer so both sides drop the message locally.
  void _handle1To1Retract(Jid to, XmlElement retractEl) {
    final targetId = retractEl.getAttribute('id');
    if (targetId == null || targetId.isEmpty) return;
    final existing = messages.findByStanzaId(_jid, to, targetId);
    if (existing == null) return;
    // Only the original sender can retract their own message.
    if (existing.from.bare.toString() != _jid.bare.toString()) return;
    messages.deleteByStanzaId(_jid, to, targetId);
    final stanza =
        '<message xmlns="${Ns.client}" from="${_esc(_jid.toString())}" '
        'to="${_esc(to.toString())}" type="chat">'
        '<retract xmlns="${Ns.messageRetract}" id="${_esc(targetId)}"/>'
        '</message>';
    router.fanOut(to.local, stanza);
    // Also echo to my own other sessions.
    for (final s in router.sessionsOf(_userId)) {
      if (identical(s, this)) continue;
      if (s is XmppWsSession) s.send(stanza);
    }
  }

  void _handleGroupRetract(Jid room, XmlElement retractEl) {
    final bubbleId = room.local;
    final bubble = bubbles.findById(bubbleId);
    if (bubble == null) return;
    final myMember = bubbles.memberOf(bubbleId, _userId);
    if (myMember == null || myMember.status != 'accepted') return;
    final targetId = retractEl.getAttribute('id');
    if (targetId == null || targetId.isEmpty) return;
    final existing = bubbles.findMessageByStanzaId(bubbleId, targetId);
    if (existing == null) return;
    // Sender check: original from is `roomJid/nick` where nick is the
    // user's local part in this stub.
    if (existing.from.local != _userId) return;
    bubbles.deleteMessageByStanzaId(bubbleId, targetId);
    final stanza =
        '<message xmlns="${Ns.client}" from="${_esc('${room.toString()}/$_userId')}" '
        'to="${_esc(room.toString())}" type="groupchat">'
        '<retract xmlns="${Ns.messageRetract}" id="${_esc(targetId)}"/>'
        '</message>';
    for (final memberId in bubbles.memberIdsOf(bubbleId)) {
      router.fanOut(memberId, stanza);
    }
  }

  String _wrapSentCarbon(String innerMessageStanza) {
    return '<message from="${_esc(_jid.bare.toString())}" '
        'to="${_esc(_jid.toString())}" type="chat">'
        '<sent xmlns="${Ns.carbons2}">'
        '<forwarded xmlns="${Ns.forward}">'
        '$innerMessageStanza'
        '</forwarded>'
        '</sent>'
        '</message>';
  }

  void _handleGroupChat(XmlElement el, Jid to, String? body) {
    final bubbleId = to.local;
    final bubble = bubbles.findById(bubbleId);
    if (bubble == null) return;
    final myMember = bubbles.memberOf(bubbleId, _userId);
    if (myMember == null || myMember.status != 'accepted') return;

    // XEP-0444 reactions on a MUC message have no <body> — persist the
    // snapshot so MAM replay for later-joining members surfaces them.
    final hasReactions = el.children.whereType<XmlElement>().any(
      (e) => e.name.namespaceUri == Ns.reactions,
    );
    if (hasReactions) _persistReactions(el);

    final stanzaId =
        el.getAttribute('id') ??
        DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    if (body != null) {
      bubbles.insertMessage(
        bubbleId: bubbleId,
        stanzaId: stanzaId,
        from: _jid,
        body: body,
      );
    }
    final forwarded = _rewriteFrom(el, id: stanzaId);
    for (final m in bubbles.membersOf(bubbleId)) {
      if (m.status != 'accepted') continue;
      router.fanOut(m.userId, forwarded);
    }
  }

  String _rewriteFrom(XmlElement el, {String? id}) {
    final copy = el.copy();
    copy.setAttribute('xmlns', Ns.client);
    copy.setAttribute('from', _jid.toString());
    if (id != null) copy.setAttribute('id', id);
    return copy.toXmlString();
  }

  void _handlePresence(XmlElement el) {
    if (_state != _State.bound) return;
    final typeAttr = el.getAttribute('type');
    final toAttr = el.getAttribute('to');

    // MUC join / leave — `<presence to="<bubbleId>@muc.<domain>/<nick>">`
    if (toAttr != null) {
      final to = Jid.parse(toAttr);
      if (to.domain.startsWith(Ns.mucPrefix)) {
        _handleMucPresence(el, to, typeAttr);
        return;
      }
    }

    // RFC 6121 §3 presence subscription. subscribe/subscribed/unsubscribe/
    // unsubscribed are routed (bare-JID addressed) to the target peer;
    // probe is answered with the target's current presence.
    if (toAttr != null &&
        (typeAttr == 'subscribe' ||
            typeAttr == 'subscribed' ||
            typeAttr == 'unsubscribe' ||
            typeAttr == 'unsubscribed' ||
            typeAttr == 'probe')) {
      _handleSubscription(typeAttr!, Jid.parse(toAttr));
      return;
    }

    if (typeAttr == 'unavailable') {
      presence.set(_userId, 'offline');
      _fanOutPresenceAvailability(unavailable: true);
      return;
    }
    final show = el.getElement('show')?.innerText.trim() ?? 'online';
    final status = el.getElement('status')?.innerText;
    presence.set(_userId, show, status: status);
    _fanOutPresenceAvailability(show: show, status: status);

    // Initial <presence/> from client — deliver each roster contact's known
    // presence back so the RN SDK can populate presence badges immediately.
    _sendRosterPresencesTo(this);
  }

  /// RFC 6121 §3 presence-subscription routing. subscribe/subscribed/
  /// unsubscribe/unsubscribed are stamped with our bare JID and fanned
  /// out to the target user's sessions. probe is answered directly with
  /// the target's last known presence.
  /// XEP-0012 Last Activity reply. `seconds` is 0 when the target is
  /// currently online, otherwise the seconds elapsed since their
  /// presence record last changed (i.e. when they went offline).
  void _replyLastActivity(String iqId, String? toAttr) {
    final targetLocal = toAttr != null ? Jid.parse(toAttr).local : _userId;
    final rec = presence.findOrDefault(targetLocal);
    final online = rec.show != 'offline';
    final elapsed = DateTime.now().toUtc().difference(rec.updatedAt).inSeconds;
    final seconds = online ? 0 : (elapsed < 0 ? 0 : elapsed);
    final fromAttr = toAttr != null ? ' from="${_esc(toAttr)}"' : '';
    send(
      '<iq type="result" id="${_esc(iqId)}"$fromAttr '
      'to="${_esc(_jid.toString())}">'
      '<query xmlns="${Ns.lastActivity}" seconds="$seconds"/>'
      '</iq>',
    );
  }

  void _handleSubscription(String type, Jid target) {
    if (type == 'probe') {
      final rec = presence.findOrDefault(target.local);
      final unavail = rec.show == 'offline';
      final buf = StringBuffer(
        '<presence from="${_esc('${target.local}@$domain')}" '
        'to="${_esc(_jid.toString())}"',
      );
      if (unavail) buf.write(' type="unavailable"');
      buf.write('>');
      if (!unavail) {
        buf.write('<show>${_esc(rec.show)}</show>');
        if (rec.status != null) {
          buf.write('<status>${_esc(rec.status!)}</status>');
        }
      }
      buf.write('</presence>');
      send(buf.toString());
      return;
    }
    final stanza =
        '<presence xmlns="${Ns.client}" from="${_esc(_jid.bare.toString())}" '
        'to="${_esc(target.bare.toString())}" type="${_esc(type)}"/>';
    router.fanOut(target.local, stanza);
  }

  void _handleMucPresence(XmlElement el, Jid to, String? type) {
    final bubbleId = to.local;
    final bubble = bubbles.findById(bubbleId);
    if (bubble == null) return;
    final me = bubbles.memberOf(bubbleId, _userId);
    if (me == null) return;

    if (type == 'unavailable') {
      // Best-effort: forward to occupants; membership stays intact.
      final leaveStanza =
          '<presence type="unavailable" from="${_esc(to.toString())}" '
          'to="${_esc(_jid.toString())}"/>';
      send(leaveStanza);
      return;
    }
    // Deliver occupant list back to the joiner.
    for (final m in bubbles.membersOf(bubbleId)) {
      if (m.status != 'accepted') continue;
      final occJid = '${bubble.id}@${Ns.mucPrefix}$domain/${m.userId}';
      send(
        '<presence from="${_esc(occJid)}" to="${_esc(_jid.toString())}">'
        '<x xmlns="${Ns.mucUser}">'
        '<item affiliation="${_esc(m.role == 'owner' ? 'owner' : 'member')}" '
        'role="participant" jid="${_esc('${m.userId}@$domain')}"/>'
        '</x></presence>',
      );
    }
    // Confirm the self-join.
    send(
      '<presence from="${_esc('${bubble.id}@${Ns.mucPrefix}$domain/$_userId')}" '
      'to="${_esc(_jid.toString())}">'
      '<x xmlns="${Ns.mucUser}">'
      '<item affiliation="${_esc(me.role == 'owner' ? 'owner' : 'member')}" '
      'role="participant" jid="${_esc(_jid.toString())}"/>'
      '<status code="110"/>'
      '</x></presence>',
    );
  }

  void _sendRosterPresencesTo(XmppSession target) {
    final entries = roster.listFor(_userId, limit: 500);
    for (final e in entries) {
      final rec = presence.findOrDefault(e.contact.id);
      final unavail = rec.show == 'offline';
      final from = '${e.contact.id}@$domain';
      final buf = StringBuffer(
        '<presence from="${_esc(from)}" to="${_esc(_jid.toString())}"',
      );
      if (unavail) buf.write(' type="unavailable"');
      buf.write('>');
      if (!unavail) {
        buf.write('<show>${_esc(rec.show)}</show>');
        if (rec.status != null)
          buf.write('<status>${_esc(rec.status!)}</status>');
      }
      buf.write('</presence>');
      target.send(buf.toString());
    }
  }

  void _fanOutPresenceAvailability({
    bool unavailable = false,
    String show = 'online',
    String? status,
  }) {
    final buf = StringBuffer('<presence from="${_esc(_jid.toString())}"');
    if (unavailable) buf.write(' type="unavailable"');
    buf.write('>');
    if (!unavailable) {
      buf.write('<show>${_esc(show)}</show>');
      if (status != null) buf.write('<status>${_esc(status)}</status>');
    }
    buf.write('</presence>');
    final stanza = buf.toString();
    router.broadcast(stanza, except: this);
  }
}

class _OutboundStanza {
  _OutboundStanza(this.h, this.stanza);
  final int h;
  final String stanza;
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
