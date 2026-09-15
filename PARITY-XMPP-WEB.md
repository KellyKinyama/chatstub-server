# Parity roadmap — `nioc/xmpp-web` client

Goal: extend `chatstub-server` so the [`xmpp-web`](../../node/xmpp-web)
browser client (`@xmpp/client` over RFC 7395) exercises **every feature
it exposes** against the stub, not just core chat.

- **Estimate legend:** S ≈ under a day · M ≈ 1–3 days · L ≈ 3–7 days
- **Status legend:** ✅ done · 🟡 partial · ⬜ open · 🕒 deferred

Branch: **`feat/xmpp-web-parity`**. Last updated: **2026-09-15**.

---

## 0. Compatibility matrix (today)

What `xmpp-web` declares in `src/services/XmppClient.js` (`NS` map) and
uses in its Vue components, vs. what the stub answers today.

| Client capability | XEP / NS | Stub today | Target phase |
|---|---|---|---|
| WS transport (RFC 7395) | `xmpp-framing` | ✅ `/websocket` | — |
| Resource bind | `xmpp-bind` | ✅ | — |
| Roster | `jabber:iq:roster` | ✅ | — |
| Presence | RFC 6121 | ✅ | — |
| 1:1 + MUC chat | XEP-0045 | ✅ (MUC light) | — |
| Disco info/items | XEP-0030 | ✅ | — |
| MAM + RSM | XEP-0313 / 0059 | ✅ | — |
| Carbons | XEP-0280 | ✅ | — |
| Chat states | XEP-0085 | ✅ | — |
| Reactions | XEP-0444 | ✅ | — |
| **Registered login** | SASL PLAIN | ✅ | — |
| **Guest / anonymous join** | SASL ANONYMOUS (RFC 4505) | ✅ | **A1** |
| **vCard / avatar edit** | XEP-0054 `vcard-temp` | ✅ | **A2** |
| **File sharing** | XEP-0363 `http:upload:0` | ✅ | **A3** |
| OOB url in message | XEP-0066 `jabber:x:oob` | ✅ forwarded | — |
| **Bookmarked rooms** | XEP-0048 / 0049 `storage:bookmarks` | ✅ | **B1** |
| **Room create / config** | XEP-0045 `muc#owner` + XEP-0004 forms | 🟡 join only | **B2** |
| MUC self-ping / request voice | `muc#request` | ⬜ | **B2** |
| **Message moderation** | XEP-0425 `message-moderate:0` | ⬜ | **C1** |
| Stanza-id stamping | XEP-0359 `sid:0` | 🟡 in MAM only | **C2** |
| Message hints | XEP-0334 `hints` | 🟡 partial | **C2** |
| Styling passthrough | XEP-0393 | ✅ (opaque body) | — |
| HTTP autodiscovery | XEP-0156 host-meta.json | ⬜ | **C3** (opt) |

---

## Phase A — unblock the visibly-broken client features

### A1 · SASL ANONYMOUS + guest/anon host (M) — ✅

- **Landed** on `feat/xmpp-web-parity` (`ee18084`): `<mechanisms>` now
  advertises `ANONYMOUS` when `anonymous.enabled`, guests bind to
  `guest-<hex>@<anonymousHost|domain>/<resource>`, presence writes are
  skipped for guests (no user row → no FK), and PLAIN is unchanged.
  Config: `anonymous.enabled` / `anonymous.host` in both YAML files.
  Tests: `test/xmpp_anonymous_test.dart` (4 cases, green).

- **What:** Advertise `ANONYMOUS` alongside `PLAIN` in `<mechanisms>`;
  on an `<auth mechanism="ANONYMOUS">` mint an ephemeral bare JID on
  the configured anon host and bind normally. Everything downstream
  (presence, MUC join, messages) already works once a session exists.
- **Why:** `xmpp-web`'s `/guest?join={jid}` flow (`Guest/*.vue`,
  `XmppSocket.create` with `jid = 'anon'`) authenticates via RFC 4505.
  Today the stub offers only PLAIN → guest login fails immediately.
- **Where:**
  - `lib/src/xmpp/session.dart` — mechanism advertising (the
    `<mechanisms …><mechanism>PLAIN</mechanism>` line) and the
    `mechanism != 'PLAIN'` guard in the auth handler.
  - `lib/src/config/` — add `anonymousHost` / `allowAnonymous` to the
    YAML loader; surface in `config/rainbow-stub.yaml`.
  - `lib/src/xmpp/jid.dart` — ephemeral local-part generator (nanoid).
- **Acceptance:** With `allowAnonymous: true`, an `@xmpp/client` using
  `sasl: ['ANONYMOUS']` binds, joins a MUC on the anon host, and
  exchanges `groupchat` messages. A new stub test
  `test/xmpp_anonymous_test.dart` drives it. PLAIN path unchanged.
- **Depends on:** nothing.

### A2 · XEP-0054 `vcard-temp` get/set (M) — ✅

- **Landed** on `feat/xmpp-web-parity`: `<iq><vCard xmlns="vcard-temp">`
  get returns the target user's FN/NICKNAME/EMAIL/PHOTO (self when
  unaddressed, synthesized from the user record when no card stored);
  set persists the authenticated user's card. PHOTO is bridged to the
  avatar store (`readSync`/`writeSync`) so REST and XMPP stay in sync.
  Guests (anon) are refused a set with `<forbidden/>`. New `vcards`
  table + `VcardRepository`; `vcard-temp` advertised in disco#info.
  Tests: `test/xmpp_vcard_test.dart` (4 cases, green).

- **What:** Answer `<iq><vCard xmlns="vcard-temp"/>` get with the
  target user's card (FN, NICKNAME, EMAIL, PHOTO), and persist a set
  for the authenticated user. Bridge PHOTO ⇆ the existing REST avatar
  store so both surfaces stay in sync.
- **Why:** `Profile.vue` / `Contact.vue` read and write vCards
  (`NS.VCARD`) for display name + avatar. No handler today.
- **Where:**
  - `lib/src/xmpp/session.dart` — new branch in the IQ dispatch (after
    the roster branch, ~L606) → `_handleVcard(id, el, type)`.
  - `lib/src/db/` — `vcards` table (user_id PK, fn, nickname, email,
    photo_mime, photo_b64) + migration; or reuse `users` + avatar blob.
  - `lib/src/users/` — reuse avatar bytes for `<PHOTO><BINVAL>`.
  - Advertise `vcard-temp` in `_replyDiscoInfo` `feats`.
- **Acceptance:** Set a vCard with FN + PHOTO; a second session's get
  returns identical FN and base64 PHOTO. Avatar set via REST is
  visible in the vCard PHOTO and vice-versa. Covered by
  `test/xmpp_vcard_test.dart`.
- **Depends on:** nothing.

### A3 · XEP-0363 HTTP File Upload (L) — ✅

- **Landed** on `feat/xmpp-web-parity`: the main domain's disco#info now
  advertises `urn:xmpp:http:upload:0` plus a `max-file-size` data form
  (so the client's `getMaxFileSize()` finds it without a separate
  component). A `<request>` IQ mints an unguessable token and returns
  `<slot>` PUT/GET URLs built from `config.publicBaseUrl`; oversize
  requests get `<file-too-large>`. New `HttpUploadService` +
  `/upload/<token>` PUT/GET routes (token is the capability, CORS via
  the existing middleware). Config: `httpUpload.enabled` /
  `httpUpload.maxFileSizeBytes`. Tests: `test/xmpp_http_upload_test.dart`
  (4 cases, green).
- **Deploy note:** `publicBaseUrl` = `<scheme>://<publicHost>:<port>`;
  behind a reverse proxy set `publicHost`/`port` (or front it) so the
  slot URLs are reachable by the browser.

- **What:** Advertise an upload component in `disco#items` +
  `disco#info` (`urn:xmpp:http:upload:0` with `max-file-size`), answer
  `<request>` slot IQs with signed PUT/GET URLs, and serve the PUT/GET
  over the existing shelf pipeline backed by the current file store.
- **Why:** `xmpp-web` composer requests a slot (`NS.HTTP_UPLOAD`), PUTs
  the bytes, then sends a message carrying `jabber:x:oob` url. Today the
  stub has a REST file API but no XMPP slot IQ → the attach button in
  the client dead-ends.
- **Where:**
  - `lib/src/xmpp/session.dart` — IQ branch for `request`
    namespace `urn:xmpp:http:upload:0` → `_handleUploadSlot`.
  - `lib/src/files/` — reuse storage; add slot-token table +
    `PUT /upload/{token}` and `GET /upload/{token}` handlers.
  - `lib/src/app.dart` — mount the upload PUT/GET routes on the router
    (next to the existing `fileRouter` mount) with CORS on GET.
  - `_replyDiscoInfo` + a new `disco#items` reply advertising the
    `upload.<domain>` service JID.
- **Acceptance:** `@xmpp/client` requests a slot, PUTs a PNG to the put
  URL (201), a second user GETs the get URL (200, correct bytes +
  content-type). `test/xmpp_http_upload_test.dart` green. Size over the
  configured cap returns `<file-too-large>`.
- **Depends on:** nothing (storage exists). Prereq for the client's
  image/file bubbles rendering end-to-end.

---

## Phase B — rooms & bookmarks

### B1 · XEP-0049 private storage + XEP-0048 bookmarks (S–M) — ✅

- **Landed** on `feat/xmpp-web-parity`: generic `jabber:iq:private`
  get/set. The single child of `<query>` is keyed by its
  `{namespace}localName` and its raw serialization is stored/returned
  verbatim, so `storage:bookmarks` rides on top unchanged. Empty get
  echoes the requested empty element; guests are refused a set with
  `<forbidden/>`. New `private_storage` table + `PrivateStorageRepository`.
  Tests: `test/xmpp_private_storage_test.dart` (4 cases, green).

- **What:** Implement `jabber:iq:private` get/set as an opaque
  per-user XML blob keyed by child element qname; `storage:bookmarks`
  rides on top for free. Return stored XML verbatim on get.
- **Why:** `xmpp-web` persists bookmarked rooms via `NS.PRIVATE` +
  `NS.BOOKMARKS` (`store/index.js`, `RoomsList.vue`). Without it the
  bookmarked-rooms list is always empty and never persists.
- **Where:**
  - `lib/src/xmpp/session.dart` — IQ branch for `query` namespace
    `jabber:iq:private` → `_handlePrivateStorage`.
  - `lib/src/db/` — `private_storage` table (user_id, element_qname,
    xml) with upsert.
- **Acceptance:** Set `storage:bookmarks` with two `<conference>`
  entries; get on a fresh session returns them byte-identical.
  `test/xmpp_private_storage_test.dart` green.
- **Depends on:** nothing.

### B2 · XEP-0045 MUC owner config + `muc#request` (L) — 🟡

- **What:** Grow "MUC light" into: room creation via presence to a
  non-existent room (creator becomes owner), `muc#owner` config form
  (`get` returns a `jabber:x:data` form, `set` applies name/subject/
  members-only/persistent), and `muc#request` voice handling.
- **Why:** `RoomCreation.vue` / `RoomConfiguration.vue` /
  `RoomConfigurationButton.vue` drive owner config forms
  (`NS.MUC_OWNER`, `NS.FORM`, `NS.MUC_REQUEST`). Today MUC is
  join-only; create/configure fail.
- **Where:**
  - `lib/src/xmpp/session.dart` / `router.dart` — owner tracking,
    config-form get/set, affiliation on create.
  - `lib/src/bubbles/` — reuse bubble (MUC) membership store as the
    room backing model.
  - `lib/src/db/` — room config columns (name, subject, membersonly,
    persistent, owner_id).
- **Acceptance:** A user creates `room@muc.<domain>`, GETs the owner
  form, POSTs a config setting subject + members-only, a second user
  joins and sees the subject. `test/xmpp_muc_owner_test.dart` green.
- **Depends on:** existing bubble/MUC store.

---

## Phase C — moderation & wire polish

### C1 · XEP-0425 message moderation (M) — ⬜

- **What:** Handle the moderation `<moderate>` IQ (owner/admin only)
  against a MUC message id; broadcast the XEP-0425 `<moderated>`
  tombstone (with XEP-0424 `<retract>`) to occupants and rewrite the
  MAM copy so late joiners see the tombstone.
- **Why:** `xmpp-web` exposes moderation (`NS.MESSAGE_MODERATION`,
  `MESSAGE_RETRACTED`) in `Shared/Message.vue`. Unhandled today.
- **Where:**
  - `lib/src/xmpp/session.dart` — IQ branch for `moderate` namespace
    `urn:xmpp:message-moderate:0`.
  - `lib/src/xmpp/router.dart` — occupant fan-out of the tombstone.
  - `lib/src/messages/` (bubble MAM) — tombstone rewrite in the store.
- **Acceptance:** Owner moderates a message; all occupants and a later
  MAM query receive the `<moderated>` tombstone; non-owner gets
  `<forbidden>`. `test/xmpp_moderation_test.dart` green.
- **Depends on:** B2 (owner/affiliation model).

### C2 · XEP-0359 stanza-id + XEP-0334 hints (S) — 🟡

- **What:** Stamp every routed `message` with a `<stanza-id>` (not just
  MAM results) and advertise `urn:xmpp:sid:0`; honor `<no-store>` /
  `<store>` hints in the persistence decision.
- **Why:** `xmpp-web` reads `NS.UNIQUE_ID` for dedupe/reply anchoring
  and `NS.STORE` for archive control. Partial today.
- **Where:** `lib/src/xmpp/session.dart` (stamp on send/route),
  `_replyDiscoInfo` feats, MAM persistence guard.
- **Acceptance:** A live `chat` message carries a `<stanza-id by=…>`;
  a `<no-store>` message is not returned by a subsequent MAM query.
- **Depends on:** nothing.

### C3 · XEP-0156 HTTP autodiscovery (S, optional) — 🕒

- **What:** Serve `/.well-known/host-meta.json` advertising the
  websocket alt-connection so `hasHttpAutoDiscovery` clients can find
  the endpoint from a bare domain.
- **Where:** `lib/src/app.dart` — a `GET /.well-known/host-meta.json`.
- **Acceptance:** `curl` returns a JSON doc with a `urn:xmpp:alt-
  connections:websocket` link to the stub's `/websocket`.
- **Depends on:** nothing. Deferred — only needed if a deployment wants
  domain-based discovery.

---

## Suggested order

1. **A1** (guest access) — ✅ done.
2. **A2** (vCard) — ✅ done.
3. **A3** (HTTP upload) — ✅ done.
4. **B1** (bookmarks) — ✅ done.
5. **B2** (MUC owner) — larger; prerequisite for moderation.
6. **C1** (moderation) → **C2** (stanza-id/hints) → **C3** (autodiscovery, opt).

Every phase lands with: a focused stub test, a `disco#info` feature
entry where applicable, and a one-line note in `README.md`'s roadmap
snapshot. Keep PLAIN + existing wire behavior byte-stable.
