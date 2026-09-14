# chatstub-server

A self-contained CPaaS-style messaging + calling backend **stub** for
local development of the sibling Flutter consumer (`chatstub_consumer`)
and any other client that speaks its REST + XMPP-over-WebSocket contract.

- **REST:** `shelf` router on `:8443` (TLS by default, self-signed
  auto-generated) — auth, users, roster, presence, avatars, bubbles
  (MUC), files, call logs, push tokens
- **XMPP/WS:** hand-rolled RFC 7395 server at `/websocket` — SASL PLAIN,
  bind, 1:1 + MUC messages, XEP-0313 MAM (RSM), XEP-0184 receipts,
  XEP-0333 markers, XEP-0085 chat states, XEP-0198 stream management
  with resume, XEP-0280 carbons, XEP-0166 Jingle passthrough, XEP-0424
  retract, XEP-0444 reactions, XEP-0308 corrections
- **Group calls:** MUC-scoped signaling marker (`urn:rainbow:muc-call:1`)
  routed to bubble members. Actual media SFU is external (ion-sfu);
  see the Flutter consumer's `docs/ion-sfu-wsl.md`
- **WebRTC 1:1:** Jingle stanzas routed opaquely to the peer — the
  clients handle SDP + ICE via `flutter_webrtc`, no server-side codec
  gymnastics

> **New here?** [RUNBOOK.md](RUNBOOK.md) has the full setup, TLS trust
> notes, endpoint reference, and troubleshooting.

## Quickstart

```powershell
cd c:\www\dart\chatstub-server
dart pub get
dart run tool/gen_cert.dart          # self-signed TLS (one-time)
dart run tool/seed.dart              # seed alice/bob / password
dart run bin/server.dart             # https://0.0.0.0:8443
```

### HTTP-only smoke config

Real Android / iOS devices don't ergonomically trust the self-signed
dev cert, so there's an alternate config that runs plain HTTP on :8080:

```powershell
dart run bin/server.dart --config config/rainbow-stub-smoke.yaml
```

Use this for `flutter run -d <device> --dart-define=STUB_SCHEME=http`
smoke runs — see the consumer's
[docs/live-smoke-test.md](../../flutter/chatstub_consumer/docs/live-smoke-test.md).

### Docker

```powershell
cd docker
docker compose up --build
```

## Client integration

React Native sample (`android/app/src/main/assets/rainbow-config.json`
or `ios/rainbow-config.json`):

```json
{
  "HOST": "10.0.2.2:8443",
  "APP_ID": "65c681c01c8f11e9add8932b358ef81d",
  "SEC_KEY": "UYdu3wCXTdfyjImhURnIkZ0tac5J9XSLszIKBRUUWVB35b6nT3fWV2BhAGhojdBQ"
}
```

Flutter consumer: [`c:\www\flutter\chatstub_consumer`](../../flutter/chatstub_consumer).
Sample device-friendly invocation:

```powershell
flutter run -d <device> `
  --dart-define=STUB_SCHEME=http `
  --dart-define=STUB_HOST=<lan-ip> `
  --dart-define=STUB_PORT=8080
```

## Testing

```powershell
dart test                                              # 40+ unit tests
dart run tool/smoke.ps1                                # full REST smoke
dart run tool/smoke-phase5-xmpp.dart                   # XMPP handshake + MUC
dart run tool/smoke-phase6-xmpp.dart                   # SM + MAM + Jingle
```

Each phase's smoke script exercises the wire from a fresh client and
prints pass/fail lines — no test framework hookup required.

## Layout

| Path | Purpose |
|---|---|
| `bin/server.dart` | Entrypoint — loads `Config`, auto-gens TLS cert, wires the shelf pipeline |
| `lib/src/app.dart` | `RainbowStubApp` — mounts every router + XMPP-WS handler under one shelf `Pipeline` (access log, error mapper, security headers, CORS) |
| `lib/src/auth/` | `/authentication/v1.0/*` + self-register + reset-password |
| `lib/src/users/` | `/enduser/v1.0/users/*` — profile, roster, networks, avatars |
| `lib/src/bubbles/` | Bubble (MUC) rooms + members + bubble MAM |
| `lib/src/messages/` | 1:1 messages, MAM query engine (RSM-aware) |
| `lib/src/files/` | Attachment upload / download |
| `lib/src/calllog/` | POST/GET/DELETE call-log entries |
| `lib/src/push/` | Push-token registration + "would-push" INFO hook |
| `lib/src/events/` | Presence + roster event bus |
| `lib/src/xmpp/` | RFC 7395 server: session, router, MAM, MUC, SM, Jingle |
| `lib/src/db/` | SQLite schema + `AppDatabase` |
| `lib/src/config/` | YAML config loader |
| `lib/src/metrics/` | Prometheus counters + gauges |
| `lib/src/util/` | IDs, error envelope, JSON helpers, logging |
| `config/` | `rainbow-stub.yaml` (TLS-on default), `rainbow-stub-smoke.yaml` (HTTP :8080) |
| `tool/` | `gen_cert.dart`, `seed.dart`, phase smoke scripts |
| `docker/` | Dockerfile + compose (joins `dart-pbx` on `rainbow-net`) |

## Roadmap

Detailed roadmap with per-phase acceptance criteria and estimates:
**[ROADMAP.md](ROADMAP.md)**.

Snapshot:

- [x] Phase 0 — scaffold, TLS, `/health`
- [x] Phase 1 — auth REST (login/logout/renew, self-register,
      reset-password), users REST
- [x] Phase 2 — roster, avatars, presence
- [x] Phase 3 — XMPP-over-WS (SASL, bind, 1:1 chat, MAM, chat states)
- [x] Phase 4 — bubbles, files, call-log, XMPP push events
- [x] Phase 5-XMPP hardening — ping, disco, roster IQ, presence probe,
      MUC light, receipts
- [x] Batch — XEP-0198 SM (enable/ack/resume), XEP-0280 carbons,
      bubble MAM, XEP-0313 RSM
- [x] Hardening — stanza size, queue caps, session caps, keepalive,
      MAM auth, SASL cap
- [x] Observability — TLS auto-gen + HSTS, JSON logs, Prometheus
      `/metrics`, XXE guard
- [x] XEP-0166 Jingle passthrough (session-initiate / -accept /
      -terminate / transport-info), XEP-0424 retract, XEP-0444 reactions
- [x] Push-token upsert / delete / list + "would-push" INFO for offline
      recipients
- [x] MUC group-call marker (`urn:rainbow:muc-call:1`) fan-out
- [x] Flutter consumer (`c:\www\flutter\chatstub_consumer`) live
      smoke — chat, calls, group calls
- [x] HTTP-only smoke config for real-device runs
- [ ] Phase 5-SIP — Asterisk ARI bridge for P2P + ConfBridge *(deferred)*
- [ ] TURN relay recipe (client-side needs it for cross-NAT calls)
