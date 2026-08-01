-- ASK indexer schema. One file.
-- Every take is a row. A round is the chain of takes between two deaths.

CREATE TABLE IF NOT EXISTS meta (
  k TEXT PRIMARY KEY,
  v TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS blocks (
  number INTEGER PRIMARY KEY,
  hash TEXT NOT NULL
);

-- One row per take. The chain of holders, in order.
CREATE TABLE IF NOT EXISTS takes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  round_id INTEGER NOT NULL,
  hop INTEGER NOT NULL,
  taker TEXT NOT NULL,
  price TEXT NOT NULL,            -- wei paid by the taker
  flipped TEXT,                   -- who they took it from (null on the opener)
  flipped_return TEXT NOT NULL,   -- wei paid back to the previous holder (105% of their cost)
  pot_added TEXT NOT NULL,        -- wei skimmed into the pot by this take
  held_seconds INTEGER NOT NULL,  -- how long the previous holder was exposed
  deadline INTEGER NOT NULL,
  block INTEGER NOT NULL,
  log_index INTEGER NOT NULL,
  tx TEXT NOT NULL,
  ts INTEGER NOT NULL,
  UNIQUE (round_id, hop)
);

-- One row per round won.
CREATE TABLE IF NOT EXISTS rounds (
  round_id INTEGER PRIMARY KEY,
  winner TEXT NOT NULL,
  won TEXT NOT NULL,              -- wei the last holder took (50% of the pot)
  pot_at_end TEXT NOT NULL,
  hops INTEGER NOT NULL,
  to_devs TEXT NOT NULL,
  to_next_pot TEXT NOT NULL,
  block INTEGER NOT NULL,
  log_index INTEGER NOT NULL,
  tx TEXT NOT NULL,
  ts INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS round_starts (
  round_id INTEGER PRIMARY KEY,
  seed TEXT NOT NULL,
  block INTEGER NOT NULL,
  ts INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS pending_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,             -- credited | claimed
  owner TEXT NOT NULL,
  amount TEXT NOT NULL,
  block INTEGER NOT NULL,
  log_index INTEGER NOT NULL,
  tx TEXT NOT NULL,
  ts INTEGER NOT NULL
);

-- Periodic state snapshot, every 15s.
CREATE TABLE IF NOT EXISTS state_snapshots (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  block INTEGER NOT NULL,
  json TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_takes_round ON takes(round_id, hop);
CREATE INDEX IF NOT EXISTS idx_takes_taker ON takes(taker);
CREATE INDEX IF NOT EXISTS idx_takes_block ON takes(block);
CREATE INDEX IF NOT EXISTS idx_rounds_block ON rounds(block);
