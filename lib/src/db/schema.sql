-- Rainbow-stub SQLite schema — phase 1 (auth + users).
-- Later phases add: bubbles, roster, invitations, messages, files, calllog.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS users (
  id             TEXT PRIMARY KEY,         -- 24-hex ObjectId
  login_email    TEXT NOT NULL UNIQUE COLLATE NOCASE,
  password_hash  TEXT NOT NULL,            -- sha256(salt || password) hex
  password_salt  TEXT NOT NULL,            -- 16 hex chars
  first_name     TEXT,
  last_name      TEXT,
  nick_name      TEXT,
  title          TEXT,
  job_title      TEXT,
  company_id     TEXT,
  language       TEXT DEFAULT 'en',
  is_active      INTEGER NOT NULL DEFAULT 1,
  is_initialized INTEGER NOT NULL DEFAULT 1,
  created_at     TEXT NOT NULL,            -- ISO-8601
  updated_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS auth_tokens (
  token           TEXT PRIMARY KEY,        -- 40-hex opaque
  user_id         TEXT NOT NULL,
  issued_at       TEXT NOT NULL,
  expires_at      TEXT NOT NULL,           -- token TTL
  renew_expires_at TEXT NOT NULL,          -- renewal window
  revoked         INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_auth_tokens_user ON auth_tokens(user_id);

-- Self-registration / password-reset email verification.
CREATE TABLE IF NOT EXISTS one_time_tokens (
  token       TEXT PRIMARY KEY,
  purpose     TEXT NOT NULL,               -- 'self-register' | 'reset-password'
  email       TEXT NOT NULL,
  payload     TEXT,                        -- opaque JSON (e.g. draft user fields)
  expires_at  TEXT NOT NULL,
  consumed_at TEXT
);

-- Phase 2: roster relationships between users.
-- Directional: (user_id -> contact_id).
CREATE TABLE IF NOT EXISTS roster (
  user_id      TEXT NOT NULL,
  contact_id   TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'accepted',   -- accepted | pending | blocked
  created_at   TEXT NOT NULL,
  PRIMARY KEY (user_id, contact_id),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  FOREIGN KEY (contact_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_roster_user ON roster(user_id);

-- Phase 2: avatars. Blob stored on disk at avatarStorePath/<userId>.
CREATE TABLE IF NOT EXISTS avatars (
  user_id     TEXT PRIMARY KEY,
  mime_type   TEXT NOT NULL,
  byte_size   INTEGER NOT NULL,
  updated_at  TEXT NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

-- Phase 2: presence. One row per user; XMPP (phase 3) will drive live updates.
CREATE TABLE IF NOT EXISTS presence (
  user_id      TEXT PRIMARY KEY,
  show         TEXT NOT NULL DEFAULT 'online',    -- online|away|dnd|offline|invisible
  status       TEXT,                              -- freeform status message
  updated_at   TEXT NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

-- Phase 3: 1:1 messages (bubble/MUC messages arrive in phase 4).
-- `from_jid`/`to_jid` are bare JIDs — <user_id>@<xmppDomain>.
CREATE TABLE IF NOT EXISTS messages (
  id            TEXT PRIMARY KEY,        -- 24-hex ObjectId
  stanza_id     TEXT NOT NULL,           -- client-provided id (or generated)
  from_jid      TEXT NOT NULL,
  to_jid        TEXT NOT NULL,
  conversation  TEXT NOT NULL,           -- bare peer JID (canonical)
  body          TEXT NOT NULL,
  sent_at       TEXT NOT NULL,
  delivered     INTEGER NOT NULL DEFAULT 0,
  read_at       TEXT
);
CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation, sent_at);
CREATE INDEX IF NOT EXISTS idx_messages_from ON messages(from_jid, sent_at);
CREATE INDEX IF NOT EXISTS idx_messages_to   ON messages(to_jid, sent_at);

-- Phase 4: bubbles (group chat rooms).
CREATE TABLE IF NOT EXISTS bubbles (
  id           TEXT PRIMARY KEY,
  name         TEXT NOT NULL,
  topic        TEXT,
  owner_id     TEXT NOT NULL,
  visibility   TEXT NOT NULL DEFAULT 'private',
  archived     INTEGER NOT NULL DEFAULT 0,
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL,
  FOREIGN KEY (owner_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS bubble_members (
  bubble_id    TEXT NOT NULL,
  user_id      TEXT NOT NULL,
  role         TEXT NOT NULL DEFAULT 'user',      -- owner|moderator|user
  status       TEXT NOT NULL DEFAULT 'accepted',  -- accepted|invited|rejected|left
  joined_at    TEXT NOT NULL,
  PRIMARY KEY (bubble_id, user_id),
  FOREIGN KEY (bubble_id) REFERENCES bubbles(id) ON DELETE CASCADE,
  FOREIGN KEY (user_id)   REFERENCES users(id)   ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_bmem_user ON bubble_members(user_id, status);

CREATE TABLE IF NOT EXISTS bubble_messages (
  id           TEXT PRIMARY KEY,
  bubble_id    TEXT NOT NULL,
  stanza_id    TEXT NOT NULL,
  from_jid     TEXT NOT NULL,
  body         TEXT NOT NULL,
  thread       TEXT,
  subject      TEXT,
  sent_at      TEXT NOT NULL,
  FOREIGN KEY (bubble_id) REFERENCES bubbles(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_bmsg_room ON bubble_messages(bubble_id, sent_at);

-- XEP-0444 reactions on messages (both 1:1 and MUC). One row per
-- (target message stanza id, reactor user id) — emojis is the full JSON
-- array snapshot, matching the XEP's "current-full-set" semantics.
CREATE TABLE IF NOT EXISTS reactions (
  target_stanza_id TEXT NOT NULL,
  from_user_id     TEXT NOT NULL,
  emojis_json      TEXT NOT NULL,
  updated_at       TEXT NOT NULL,
  PRIMARY KEY (target_stanza_id, from_user_id)
);
CREATE INDEX IF NOT EXISTS idx_reactions_target ON reactions(target_stanza_id);

-- Phase 4: shared file descriptors. Blob lives at fileStorePath/<id>.
CREATE TABLE IF NOT EXISTS file_descriptors (
  id            TEXT PRIMARY KEY,
  owner_id      TEXT NOT NULL,
  peer_jid      TEXT NOT NULL,           -- recipient bare JID (user or bubble)
  peer_type     TEXT NOT NULL,           -- user|bubble
  file_name     TEXT NOT NULL,
  mime_type     TEXT NOT NULL,
  byte_size     INTEGER NOT NULL DEFAULT 0,
  state         TEXT NOT NULL DEFAULT 'pending', -- pending|uploaded|deleted
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  FOREIGN KEY (owner_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_files_peer ON file_descriptors(peer_jid);
CREATE INDEX IF NOT EXISTS idx_files_owner ON file_descriptors(owner_id);

-- Phase 8: push notification device tokens. One row per (user, token).
-- Used by the push dispatcher to log "would-push" events when the
-- recipient has no active XMPP session.
CREATE TABLE IF NOT EXISTS push_tokens (
  user_id     TEXT NOT NULL,
  token       TEXT NOT NULL,
  platform    TEXT NOT NULL,             -- ios|android|web|debug
  updated_at  TEXT NOT NULL,
  PRIMARY KEY (user_id, token),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_push_tokens_user ON push_tokens(user_id);

-- Phase 4: call log (populated by ARI events in phase 5; REST-serve now).
CREATE TABLE IF NOT EXISTS call_log (
  id            TEXT PRIMARY KEY,
  owner_id      TEXT NOT NULL,
  peer_jid      TEXT NOT NULL,
  peer_display  TEXT,
  direction     TEXT NOT NULL,           -- incoming|outgoing
  state         TEXT NOT NULL,           -- answered|missed|declined|failed
  media         TEXT NOT NULL DEFAULT 'audio', -- audio|video
  started_at    TEXT NOT NULL,
  duration_ms   INTEGER NOT NULL DEFAULT 0,
  read_at       TEXT,
  FOREIGN KEY (owner_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_calllog_owner ON call_log(owner_id, started_at);
