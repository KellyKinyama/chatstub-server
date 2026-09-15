import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth/auth_service.dart';
import 'auth/routes.dart';
import 'auth/token_store.dart';
import 'bubbles/bubble_repository.dart';
import 'bubbles/routes.dart' as bubble_routes;
import 'calllog/calllog_repository.dart';
import 'calllog/routes.dart' as calllog_routes;
import 'config/config.dart';
import 'db/database.dart';
import 'events/event_pusher.dart';
import 'files/file_store.dart';
import 'files/http_upload.dart';
import 'files/http_upload_routes.dart' as upload_routes;
import 'files/routes.dart' as file_routes;
import 'messages/message_repository.dart';
import 'messages/reaction_repository.dart';
import 'metrics/metrics.dart';
import 'push/push_token_repository.dart';
import 'push/routes.dart' as push_routes;
import 'sip/sip_gateway.dart';
import 'users/avatar_store.dart';
import 'users/presence_repository.dart';
import 'users/roster_repository.dart';
import 'users/routes.dart';
import 'users/user_repository.dart';
import 'users/vcard_repository.dart';
import 'util/errors.dart';
import 'util/ids.dart';
import 'xmpp/router.dart';
import 'xmpp/session.dart';
import 'xmpp/ws_server.dart';

class RainbowStubApp {
  RainbowStubApp({
    required this.config,
    required this.db,
    required this.users,
    required this.roster,
    required this.presence,
    required this.avatars,
    required this.vcards,
    required this.messages,
    required this.reactions,
    required this.bubbles,
    required this.files,
    required this.upload,
    required this.callLog,
    required this.tokens,
    required this.pushTokens,
    required this.auth,
    required this.xmppRouter,
    required this.smRegistry,
    required this.events,
    required this.metrics,
    this.sipGateway,
  });

  final Config config;
  final AppDatabase db;
  final UserRepository users;
  final RosterRepository roster;
  final PresenceRepository presence;
  final AvatarStore avatars;
  final VcardRepository vcards;
  final MessageRepository messages;
  final ReactionRepository reactions;
  final BubbleRepository bubbles;
  final FileStore files;
  final HttpUploadService upload;
  final CallLogRepository callLog;
  final TokenStore tokens;
  final PushTokenRepository pushTokens;
  final AuthService auth;
  final StanzaRouter xmppRouter;
  final SmRegistry smRegistry;
  final EventPusher events;
  final MetricsRegistry metrics;
  final SipGateway? sipGateway;

  static Future<RainbowStubApp> boot(Config config) async {
    final db = await AppDatabase.open(
      path: config.dbPath,
      schemaSqlPath: 'lib/src/db/schema.sql',
    );
    final ids = ObjectIdGen();
    final users = UserRepository(db, ids);
    final roster = RosterRepository(db, users);
    final presence = PresenceRepository(db);
    final avatars = AvatarStore(rootDir: config.avatarStorePath, db: db);
    final vcards = VcardRepository(db);
    final messages = MessageRepository(db, ids);
    final reactions = ReactionRepository(db);
    final bubbles = BubbleRepository(db, ids);
    final files = FileStore(rootDir: config.fileStorePath, db: db, ids: ids);
    final upload = HttpUploadService(
      rootDir: '${config.fileStorePath}${Platform.pathSeparator}upload',
      maxFileSize: config.httpUpload.enabled
          ? config.httpUpload.maxFileSizeBytes
          : 0,
    );
    final callLog = CallLogRepository(db, ids);
    final tokens = TokenStore(db);
    final pushTokens = PushTokenRepository(db);
    final auth = AuthService(config: config, users: users, tokens: tokens);
    final xmppRouter = StanzaRouter();
    final smRegistry = SmRegistry();
    final events = EventPusher(xmppRouter, config.xmppDomain);
    final metrics = _initMetrics(xmppRouter, smRegistry, users, bubbles);
    // Ensure every roster entry has a reciprocal so demo re-logins
    // (e.g. sign in as Bob after Alice added him) see each other.
    final mirrored = roster.mirrorAll();
    if (mirrored > 0) {
      Logger(
        'rainbow-stub.boot',
      ).info('mirrored $mirrored asymmetric roster entries');
    }
    SipGateway? sipGateway;
    if (config.sip.enabled) {
      sipGateway = await SipGateway.boot(
        config: config.sip,
        xmppDomain: config.xmppDomain,
        router: xmppRouter,
        users: users,
        messages: messages,
        callLog: callLog,
        metrics: metrics,
      );
    }
    return RainbowStubApp(
      config: config,
      db: db,
      users: users,
      roster: roster,
      presence: presence,
      avatars: avatars,
      vcards: vcards,
      messages: messages,
      reactions: reactions,
      bubbles: bubbles,
      files: files,
      upload: upload,
      callLog: callLog,
      tokens: tokens,
      pushTokens: pushTokens,
      auth: auth,
      xmppRouter: xmppRouter,
      smRegistry: smRegistry,
      events: events,
      metrics: metrics,
      sipGateway: sipGateway,
    );
  }

  Handler buildHandler() {
    final wsHandler = xmppWebSocketHandler(
      domain: config.xmppDomain,
      auth: auth,
      users: users,
      presence: presence,
      messages: messages,
      reactions: reactions,
      bubbles: bubbles,
      roster: roster,
      router: xmppRouter,
      smRegistry: smRegistry,
      pushTokens: pushTokens,
      avatars: avatars,
      vcards: vcards,
      upload: upload,
      uploadBaseUrl: config.publicBaseUrl,
      allowAnonymous: config.anonymous.enabled,
      anonymousHost: config.anonymous.host,
      sipGateway: sipGateway,
    );
    final router = Router()
      ..get(
        '/health',
        (Request _) => Response.ok(
          jsonEncode({'ok': true}),
          headers: const {'content-type': 'application/json'},
        ),
      )
      ..get('/websocket', wsHandler);
    if (config.httpUpload.enabled) {
      router.mount('/', upload_routes.httpUploadRouter(upload).call);
    }
    if (config.metrics.enabled) {
      router.get(config.metrics.path, (Request _) {
        return Response.ok(
          metrics.render(),
          headers: const {'content-type': 'text/plain; version=0.0.4'},
        );
      });
    }
    router
      ..mount('/', authRouter(auth: auth, users: users, db: db).call)
      ..mount(
        '/',
        userRouter(
          auth: auth,
          users: users,
          roster: roster,
          presence: presence,
          avatars: avatars,
          events: events,
        ).call,
      )
      ..mount(
        '/',
        bubble_routes
            .bubbleRouter(
              auth: auth,
              users: users,
              bubbles: bubbles,
              events: events,
            )
            .call,
      )
      ..mount(
        '/',
        file_routes.fileRouter(auth: auth, files: files, events: events).call,
      )
      ..mount('/', calllog_routes.callLogRouter(auth: auth, log: callLog).call)
      ..mount('/', push_routes.pushRouter(auth: auth, tokens: pushTokens).call);

    return Pipeline()
        .addMiddleware(_accessLog(metrics))
        .addMiddleware(_cors())
        .addMiddleware(_errorMapper())
        .addMiddleware(_securityHeaders(config.tls))
        .addHandler(router.call);
  }

  /// Graceful shutdown — closes every active and parked XMPP session,
  /// then closes the DB. Intended for SIGINT/SIGTERM handlers.
  Future<void> shutdown() async {
    final active = xmppRouter.sessions.toList();
    final parked = smRegistry.allSessions().toList();
    final all = [...active, ...parked];
    Logger('rainbow-stub').info(
      'shutdown — closing ${all.length} sessions '
      '(active=${active.length} parked=${parked.length})',
    );
    for (final s in all) {
      if (s is XmppWsSession) {
        await s.finalize();
      }
    }
    await sipGateway?.stop();
    db.close();
  }
}

// ---- middleware -------------------------------------------------------------

Middleware _accessLog(MetricsRegistry metrics) {
  final log = Logger('http');
  return (inner) => (req) async {
    final sw = Stopwatch()..start();
    try {
      final res = await inner(req);
      final dur = sw.elapsedMicroseconds / 1e6;
      log.log(
        Level.INFO,
        '${req.method} ${req.requestedUri.path} '
        '${res.statusCode} ${sw.elapsedMilliseconds}ms',
        <String, Object?>{
          'method': req.method,
          'path': req.requestedUri.path,
          'status': res.statusCode,
          'duration_ms': sw.elapsedMilliseconds,
          'remote': req.headers['x-forwarded-for'] ?? req.headers['host'] ?? '',
        },
      );
      metrics.inc(
        'rainbow_stub_http_requests_total',
        labels: {'method': req.method, 'code': res.statusCode.toString()},
      );
      metrics.observe(
        'rainbow_stub_http_request_duration_seconds',
        dur,
        labels: {'method': req.method},
      );
      return res;
    } on HijackException {
      log.log(
        Level.INFO,
        '${req.method} ${req.requestedUri.path} '
        'HIJACK ${sw.elapsedMilliseconds}ms',
        <String, Object?>{
          'method': req.method,
          'path': req.requestedUri.path,
          'status': 101,
          'duration_ms': sw.elapsedMilliseconds,
          'hijack': true,
        },
      );
      metrics.inc(
        'rainbow_stub_http_requests_total',
        labels: {'method': req.method, 'code': '101'},
      );
      rethrow;
    } catch (e, st) {
      log.severe('${req.method} ${req.requestedUri.path} FAILED', e, st);
      metrics.inc(
        'rainbow_stub_http_requests_total',
        labels: {'method': req.method, 'code': '500'},
      );
      rethrow;
    }
  };
}

Middleware _errorMapper() {
  final log = Logger('http.err');
  return (inner) => (req) async {
    try {
      return await inner(req);
    } on HijackException {
      rethrow;
    } on RainbowError catch (e) {
      return e.toResponse();
    } on FormatException catch (e) {
      return RainbowError.badRequest(
        'Malformed JSON: ${e.message}',
      ).toResponse();
    } catch (e, st) {
      log.severe('unhandled', e, st);
      return RainbowError(
        httpStatus: 500,
        errorCode: 500,
        errorMsg: 'Internal error',
        errorDetails: e.toString(),
      ).toResponse();
    }
  };
}

Middleware _cors() {
  const headers = {
    'access-control-allow-origin': '*',
    'access-control-allow-headers':
        'authorization,content-type,x-rainbow-app-auth,x-rainbow-client,x-rainbow-client-version',
    'access-control-allow-methods': 'GET,POST,PUT,DELETE,OPTIONS',
  };
  return (inner) => (req) async {
    if (req.method == 'OPTIONS') {
      return Response.ok('', headers: headers);
    }
    final res = await inner(req);
    return res.change(headers: {...res.headers, ...headers});
  };
}

Middleware _securityHeaders(TlsConfig tls) {
  // Static headers (order matches OWASP recommendations).
  final base = <String, String>{
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
    'referrer-policy': 'no-referrer',
    'permissions-policy': 'geolocation=(), microphone=(), camera=()',
  };
  return (inner) => (req) async {
    final res = await inner(req);
    final headers = {...res.headers, ...base};
    // Only advertise HSTS when the request actually reached us over TLS,
    // otherwise browsers cache a broken policy.
    if (tls.enabled && req.requestedUri.scheme == 'https') {
      headers['strict-transport-security'] = tls.hstsHeader;
    }
    return res.change(headers: headers);
  };
}

MetricsRegistry _initMetrics(
  StanzaRouter router,
  SmRegistry sm,
  UserRepository users,
  BubbleRepository bubbles,
) {
  final m = MetricsRegistry()
    ..registerHelp(
      name: 'rainbow_stub_http_requests_total',
      help: 'HTTP requests handled, by method and status code.',
      type: 'counter',
    )
    ..registerHelp(
      name: 'rainbow_stub_http_request_duration_seconds',
      help: 'HTTP request latency in seconds.',
      type: 'histogram',
    )
    ..registerHelp(
      name: 'rainbow_stub_xmpp_sessions',
      help: 'Currently active XMPP-over-WS sessions.',
      type: 'gauge',
    )
    ..registerHelp(
      name: 'rainbow_stub_xmpp_sm_parked',
      help: 'Sessions currently parked in the SM registry awaiting resume.',
      type: 'gauge',
    )
    ..registerHelp(
      name: 'rainbow_stub_build_info',
      help: 'Build info; label values carry version/commit.',
      type: 'gauge',
    );
  m
    ..gaugeCallback(
      'rainbow_stub_xmpp_sessions',
      () => router.sessions.length.toDouble(),
    )
    ..gaugeCallback(
      'rainbow_stub_xmpp_sm_parked',
      () => sm.heldCount.toDouble(),
    )
    ..setGauge(
      'rainbow_stub_build_info',
      1,
      labels: const {'version': '0.1.0'},
    );
  return m;
}
