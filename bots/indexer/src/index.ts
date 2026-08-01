// ASK indexer. Mirrors the contract's events into SQLite and serves a small
// REST + SSE API so the page renders the chain instantly instead of replaying
// logs on load. The contract stays the source of truth: the page reads the
// live clock and price straight from chain and uses this for history.
//
// Env:
//   RPC_URL       http(s) rpc endpoint          (default http://127.0.0.1:8545)
//   WS_URL        ws(s) endpoint if available   (optional)
//   ASK_ADDRESS   deployed Ask contract         (required)
//   START_BLOCK   first block to index          (default 0)
//   PORT          api port                      (default 8747)
//   DB_PATH       sqlite file                   (default ./ask.db)

import { createPublicClient, http, type PublicClient, type Log } from "viem";
import { DatabaseSync } from "node:sqlite";
import { createServer, type ServerResponse } from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { askAbi } from "./abi.js";

const RPC_URL = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const ASK_ADDRESS = (process.env.ASK_ADDRESS ?? "") as `0x${string}`;
const START_BLOCK = BigInt(process.env.START_BLOCK ?? "0");
const PORT = Number(process.env.PORT ?? 8747);
const DB_PATH = process.env.DB_PATH ?? "./ask.db";
const POLL_MS = 1000; // the clock is 60s; stay tight
const SNAPSHOT_MS = 15_000;
const MAX_RANGE = 500n;
const REORG_KEEP = 256;

if (!ASK_ADDRESS) {
  console.error("ASK_ADDRESS is required");
  process.exit(1);
}

const here = dirname(fileURLToPath(import.meta.url));
const db = new DatabaseSync(DB_PATH);
db.exec(readFileSync(join(here, "..", "schema.sql"), "utf8"));

const getMeta = db.prepare("SELECT v FROM meta WHERE k = ?");
const setMeta = db.prepare("INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v");

function lastBlock(): bigint {
  const row = getMeta.get("last_block") as { v: string } | undefined;
  return row ? BigInt(row.v) : START_BLOCK - 1n;
}

const client: PublicClient = createPublicClient({ transport: http(RPC_URL) });

// ── writes ─────────────────────────────────────────────────────────────────

const insTake = db.prepare(
  `INSERT OR IGNORE INTO takes
   (round_id, hop, taker, price, flipped, flipped_return, pot_added, held_seconds, deadline, block, log_index, tx, ts)
   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`
);
const insRound = db.prepare(
  `INSERT OR REPLACE INTO rounds
   (round_id, winner, won, pot_at_end, hops, to_devs, to_next_pot, block, log_index, tx, ts)
   VALUES (?,?,?,?,?,?,?,?,?,?,?)`
);
const insStart = db.prepare("INSERT OR REPLACE INTO round_starts (round_id, seed, block, ts) VALUES (?,?,?,?)");
const insPending = db.prepare(
  "INSERT INTO pending_events (kind, owner, amount, block, log_index, tx, ts) VALUES (?,?,?,?,?,?,?)"
);

const ZERO = "0x0000000000000000000000000000000000000000";

type Decoded = { eventName: string; args: Record<string, any> } & Log;

function applyEvent(ev: Decoded, ts: number) {
  const bn = Number(ev.blockNumber);
  const li = Number(ev.logIndex);
  const tx = ev.transactionHash ?? "";
  const a = ev.args;
  switch (ev.eventName) {
    case "Taken":
      insTake.run(
        Number(a.roundId),
        Number(a.hop),
        String(a.taker).toLowerCase(),
        String(a.pricePaid),
        String(a.flipped).toLowerCase() === ZERO ? null : String(a.flipped).toLowerCase(),
        String(a.flippedReturn),
        String(a.potAdded),
        Number(a.heldSeconds),
        Number(a.deadline),
        bn,
        li,
        tx,
        ts
      );
      break;
    case "RoundWon":
      insRound.run(
        Number(a.roundId),
        String(a.winner).toLowerCase(),
        String(a.won),
        String(a.potAtEnd),
        Number(a.hops),
        String(a.toDevs),
        String(a.toNextPot),
        bn,
        li,
        tx,
        ts
      );
      break;
    case "RoundStarted":
      insStart.run(Number(a.roundId), String(a.seed), bn, ts);
      break;
    case "PendingCredited":
      insPending.run("credited", String(a.owner).toLowerCase(), String(a.amount), bn, li, tx, ts);
      break;
    case "PendingClaimed":
      insPending.run("claimed", String(a.owner).toLowerCase(), String(a.amount), bn, li, tx, ts);
      break;
  }
}

// ── reorg handling ─────────────────────────────────────────────────────────

async function reorgCheckpoint(): Promise<bigint> {
  const rows = db.prepare("SELECT number, hash FROM blocks ORDER BY number DESC").all() as Array<{
    number: number;
    hash: string;
  }>;
  for (const r of rows) {
    const onchain = await client.getBlock({ blockNumber: BigInt(r.number) }).catch(() => null);
    if (onchain && onchain.hash === r.hash) return BigInt(r.number);
    console.warn(`reorg: block ${r.number} hash mismatch, walking back`);
  }
  return START_BLOCK - 1n;
}

function rollbackTo(block: bigint) {
  const b = Number(block);
  db.exec("BEGIN");
  try {
    db.prepare("DELETE FROM takes WHERE block > ?").run(b);
    db.prepare("DELETE FROM rounds WHERE block > ?").run(b);
    db.prepare("DELETE FROM round_starts WHERE block > ?").run(b);
    db.prepare("DELETE FROM pending_events WHERE block > ?").run(b);
    db.prepare("DELETE FROM blocks WHERE number > ?").run(b);
    setMeta.run("last_block", block.toString());
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
  console.warn(`rolled back to block ${block}`);
}

// ── indexing loop ──────────────────────────────────────────────────────────

const tsCache = new Map<string, number>();
async function blockTs(n: bigint): Promise<number> {
  const k = n.toString();
  const hit = tsCache.get(k);
  if (hit !== undefined) return hit;
  const b = await client.getBlock({ blockNumber: n });
  const t = Number(b.timestamp);
  tsCache.set(k, t);
  if (tsCache.size > 2048) tsCache.delete(tsCache.keys().next().value!);
  return t;
}

async function tick() {
  const tip = await client.getBlockNumber();
  let from = lastBlock() + 1n;
  if (tip < from) return;

  const prev = db.prepare("SELECT number, hash FROM blocks ORDER BY number DESC LIMIT 1").get() as
    | { number: number; hash: string }
    | undefined;
  if (prev) {
    const onchain = await client.getBlock({ blockNumber: BigInt(prev.number) }).catch(() => null);
    if (!onchain || onchain.hash !== prev.hash) {
      rollbackTo(await reorgCheckpoint());
      from = lastBlock() + 1n;
    }
  }

  const to = tip - from >= MAX_RANGE ? from + MAX_RANGE - 1n : tip;
  const logs = (await client.getContractEvents({
    abi: askAbi,
    address: ASK_ADDRESS,
    fromBlock: from,
    toBlock: to,
  })) as unknown as Decoded[];
  logs.sort((x, y) =>
    x.blockNumber === y.blockNumber ? Number(x.logIndex) - Number(y.logIndex) : Number(x.blockNumber! - y.blockNumber!)
  );

  const tsByBlock = new Map<string, number>();
  for (const l of logs) {
    const k = l.blockNumber!.toString();
    if (!tsByBlock.has(k)) tsByBlock.set(k, await blockTs(l.blockNumber!));
  }
  const toHash = (await client.getBlock({ blockNumber: to })).hash;

  db.exec("BEGIN");
  try {
    for (const l of logs) applyEvent(l, tsByBlock.get(l.blockNumber!.toString())!);
    db.prepare("INSERT OR REPLACE INTO blocks (number, hash) VALUES (?, ?)").run(Number(to), toHash);
    db.prepare("DELETE FROM blocks WHERE number < ?").run(Number(to) - REORG_KEEP);
    setMeta.run("last_block", to.toString());
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }

  for (const l of logs) broadcast({ type: l.eventName, args: jsonSafe(l.args), block: Number(l.blockNumber) });
  if (logs.length) {
    console.log(`indexed ${logs.length} events, blocks ${from}..${to}`);
    liveState().then((s) => broadcast({ type: "state", ...s })).catch(() => {});
  }
}

// ── reads ──────────────────────────────────────────────────────────────────

async function liveState() {
  const s = (await client.readContract({
    abi: askAbi,
    address: ASK_ADDRESS,
    functionName: "state",
  })) as readonly [bigint, bigint, string, bigint, bigint, bigint, bigint, bigint, bigint, boolean];
  const [round, price, holder, holderPaid, secondsLeft, heldSeconds, pot, winnerTake, hops, expired] = s;
  return {
    round: Number(round),
    price: price.toString(),
    holder,
    holderPaid: holderPaid.toString(),
    secondsLeft: Number(secondsLeft),
    heldSeconds: Number(heldSeconds),
    pot: pot.toString(),
    winnerTake: winnerTake.toString(),
    hops: Number(hops),
    expired,
    serverTime: Math.floor(Date.now() / 1000),
  };
}

function chainOf(round: number) {
  return db
    .prepare(
      `SELECT hop, taker, price, flipped, flipped_return, pot_added, held_seconds, ts, tx
       FROM takes WHERE round_id = ? ORDER BY hop DESC`
    )
    .all(round);
}

async function snapshot() {
  const st = await liveState();
  db.prepare("INSERT INTO state_snapshots (ts, block, json) VALUES (?,?,?)").run(
    Math.floor(Date.now() / 1000),
    Number(await client.getBlockNumber()),
    JSON.stringify(st)
  );
  db.prepare("DELETE FROM state_snapshots WHERE id < (SELECT MAX(id) FROM state_snapshots) - 5760").run();
  broadcast({ type: "state", ...st });
  return st;
}

// ── api ────────────────────────────────────────────────────────────────────

const sseClients = new Set<ServerResponse>();

function jsonSafe(x: unknown): any {
  return JSON.parse(JSON.stringify(x, (_, v) => (typeof v === "bigint" ? v.toString() : v)));
}

function broadcast(msg: unknown) {
  const line = `data: ${JSON.stringify(jsonSafe(msg))}\n\n`;
  for (const res of sseClients) res.write(line);
}

function send(res: ServerResponse, code: number, body: unknown) {
  res.writeHead(code, { "content-type": "application/json", "access-control-allow-origin": "*" });
  res.end(JSON.stringify(jsonSafe(body)));
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", "http://x");
  const p = url.pathname;
  try {
    if (p === "/health") return send(res, 200, { ok: true, lastBlock: lastBlock().toString() });

    // Live clock, price, holder — straight from chain.
    if (p === "/state") return send(res, 200, await liveState());

    // The chain of holders for a round (defaults to the live one).
    if (p === "/chain") {
      const q = url.searchParams.get("round");
      const round = q ? Number(q) : (await liveState()).round;
      return send(res, 200, { round, takes: chainOf(round) });
    }

    // Past rounds: who died, how much, how long the chain got.
    if (p === "/rounds") {
      const limit = Math.min(Number(url.searchParams.get("limit") ?? 25), 200);
      return send(res, 200, db.prepare("SELECT * FROM rounds ORDER BY round_id DESC LIMIT ?").all(limit));
    }

    // Everything that happened lately, newest first, for the ticker.
    if (p === "/events") {
      const limit = Math.min(Number(url.searchParams.get("limit") ?? 40), 200);
      return send(
        res,
        200,
        db
          .prepare(
            `SELECT 'take' AS kind, round_id, hop, taker AS who, price AS amount, flipped_return AS extra,
                    held_seconds AS held, block, log_index, ts FROM takes
             UNION ALL
             SELECT 'win', round_id, hops, winner, won, pot_at_end, 0, block, log_index, ts FROM rounds
             ORDER BY block DESC, log_index DESC LIMIT ?`
          )
          .all(limit)
      );
    }

    if (p.startsWith("/player/")) {
      const who = p.slice("/player/".length).toLowerCase();
      const takes = db.prepare("SELECT * FROM takes WHERE taker = ? ORDER BY id DESC LIMIT 100").all(who);
      const wins = db.prepare("SELECT * FROM rounds WHERE winner = ? ORDER BY round_id DESC").all(who) as any[];
      const flips = db.prepare("SELECT COUNT(*) AS n FROM takes WHERE flipped = ?").get(who) as any;
      return send(res, 200, { takes, wins, timesFlipped: flips?.n ?? 0 });
    }

    if (p === "/stream") {
      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive",
        "access-control-allow-origin": "*",
      });
      res.write(": connected\n\n");
      sseClients.add(res);
      req.on("close", () => sseClients.delete(res));
      return;
    }

    return send(res, 404, { error: "not found" });
  } catch (e) {
    return send(res, 500, { error: String(e) });
  }
});

// ── main ───────────────────────────────────────────────────────────────────

async function main() {
  console.log(`ask-indexer: ${ASK_ADDRESS} via ${RPC_URL}, db ${DB_PATH}`);
  server.listen(PORT, () => console.log(`api on :${PORT}`));

  const loop = async () => {
    try {
      await tick();
    } catch (e) {
      console.error("tick failed:", e);
    }
    setTimeout(loop, POLL_MS);
  };
  loop();

  setInterval(() => snapshot().catch((e) => console.error("snapshot failed:", e)), SNAPSHOT_MS);
}

main();
