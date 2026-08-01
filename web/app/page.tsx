"use client";

// ASK — one page. Hold it when the clock stops.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  useAccount,
  useConnect,
  useDisconnect,
  usePublicClient,
  useReadContract,
  useSwitchChain,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import {
  ASK_ADDRESS,
  CHAIN_ID,
  CHAIN_NAME,
  INDEXER_URL,
  START_PRICE,
  TIMER_BONUS,
  TIMER_MAX,
  askAbi,
  bluntError,
  fmtDuration,
  fmtEth,
  shortAddr,
  timeAgo,
} from "@/lib/ask";

type Take = {
  hop: number;
  taker: string;
  price: string;
  flipped: string | null;
  flipped_return: string;
  pot_added: string;
  held_seconds: number;
  ts: number;
};
type Won = { round_id: number; winner: string; won: string; pot_at_end: string; hops: number; ts: number };

const ZERO = "0x0000000000000000000000000000000000000000";

export default function Page() {
  // The server has no wallet, the browser reconnects before React hydrates, and
  // the two renders disagree — which throws away the server HTML. Everything
  // that depends on a wallet waits for mount, so the first client render is
  // identical to the server's.
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  const { address, isConnected: walletConnected, chainId } = useAccount();
  const isConnected = mounted && walletConnected;
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, isPending: switching } = useSwitchChain();

  // The wallet is on some other chain. Every write would revert with a message
  // nobody can act on, so we ask for the switch instead of letting them try.
  const wrongNetwork = isConnected && chainId !== undefined && chainId !== CHAIN_ID;

  const switchNet = useCallback(() => {
    setUiError("");
    switchChain(
      { chainId: CHAIN_ID },
      { onError: (e) => setUiError(bluntError(e)) }
    );
  }, [switchChain]);
  const [uiError, setUiError] = useState("");

  // EIP-6963: every installed wallet announces itself, so `connectors` already
  // holds MetaMask, Phantom, Rabby, Coinbase and friends without naming any of
  // them here. The bare `injected` connector is only a fallback for a wallet
  // that never announced, so drop it the moment anything did — otherwise the
  // same wallet shows up twice, once under its own name and once as "Injected".
  const wallets = useMemo(() => {
    const announced = connectors.filter((c) => c.id !== "injected");
    return announced.length > 0 ? announced : [...connectors];
  }, [connectors]);

  const [picking, setPicking] = useState(false);

  // `connect` swallows failures into its own state, so route them through the
  // one error line. With nothing installed this is what actually reports it:
  // the `injected` fallback is always present as a connector, it just has no
  // provider behind it.
  const attempt = useCallback(
    (c: (typeof wallets)[number]) => {
      setPicking(false);
      connect({ connector: c }, { onError: (e) => setUiError(bluntError(e)) });
    },
    [connect]
  );

  const doConnect = useCallback(() => {
    setUiError("");
    // One wallet is not a choice. Don't make them click twice.
    if (wallets.length === 1) return attempt(wallets[0]);
    setPicking(true);
  }, [attempt, wallets]);

  // ── live state, straight from chain ──────────────────────────────────────
  const stateQ = useReadContract({
    abi: askAbi,
    address: ASK_ADDRESS,
    functionName: "state",
    query: { refetchInterval: 2000 },
  });

  const st = stateQ.data as
    | readonly [bigint, bigint, `0x${string}`, bigint, bigint, bigint, bigint, bigint, bigint, boolean]
    | undefined;
  const round = st ? Number(st[0]) : 0;
  const price = st ? st[1] : START_PRICE;
  const holder = st ? st[2] : ZERO;
  const holderPaid = st ? st[3] : 0n;
  const heldSeconds = st ? Number(st[5]) : 0;
  const pot = st ? st[6] : 0n;
  const winnerTake = st ? st[7] : 0n;
  const hops = st ? Number(st[8]) : 0;
  const expired = st ? st[9] : false;

  const iAmHolding = isConnected && !!address && holder.toLowerCase() === address.toLowerCase();
  const roundLive = holder !== ZERO && !expired;

  // What the current holder is paid if someone takes it from them (105%).
  const exitQ = useReadContract({
    abi: askAbi,
    address: ASK_ADDRESS,
    functionName: "holderExitValue",
    query: { refetchInterval: 4000 },
  });
  const exitValue = (exitQ.data as bigint | undefined) ?? 0n;

  // Unclaimed payouts (a push that failed).
  const pendingQ = useReadContract({
    abi: askAbi,
    address: ASK_ADDRESS,
    functionName: "pendingWithdrawals",
    args: [address ?? ZERO],
    query: { enabled: !!address, refetchInterval: 8000 },
  });
  const pending = (pendingQ.data as bigint | undefined) ?? 0n;

  // ── the clock, ticking locally between reads ─────────────────────────────
  const [left, setLeft] = useState(0);
  const anchor = useRef<{ at: number; secs: number }>({ at: Date.now(), secs: 0 });

  useEffect(() => {
    if (!st) return;
    anchor.current = { at: Date.now(), secs: Number(st[4]) };
    setLeft(Number(st[4]));
  }, [st]);

  useEffect(() => {
    const iv = setInterval(() => {
      const elapsed = (Date.now() - anchor.current.at) / 1000;
      setLeft(Math.max(0, anchor.current.secs - elapsed));
    }, 100);
    return () => clearInterval(iv);
  }, []);

  // ── indexer: chain, winners ──────────────────────────────────────────────
  const [chain, setChain] = useState<Take[]>([]);
  const [winners, setWinners] = useState<Won[]>([]);
  const [flashHop, setFlashHop] = useState<number | null>(null);

  const refresh = useCallback(async () => {
    try {
      const [c, w] = await Promise.all([
        fetch(`${INDEXER_URL}/chain`).then((x) => x.json()),
        fetch(`${INDEXER_URL}/rounds?limit=8`).then((x) => x.json()),
      ]);
      setChain(c.takes ?? []);
      setWinners(w ?? []);
    } catch {
      /* indexer down: the clock and the take button still work off chain reads */
    }
  }, []);

  useEffect(() => {
    refresh();
    let es: EventSource | null = null;
    try {
      es = new EventSource(`${INDEXER_URL}/stream`);
      es.onmessage = (m) => {
        try {
          const d = JSON.parse(m.data);
          if (d.type === "Taken") {
            setFlashHop(Number(d.args?.hop ?? 0));
            setTimeout(() => setFlashHop(null), 900);
          }
          if (d.type === "Taken" || d.type === "RoundWon" || d.type === "RoundStarted") {
            stateQ.refetch();
            refresh();
          }
        } catch {}
      };
    } catch {}
    const iv = setInterval(refresh, 10_000);
    return () => {
      es?.close();
      clearInterval(iv);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [refresh]);

  // ── writes ───────────────────────────────────────────────────────────────
  const { writeContractAsync } = useWriteContract();
  const publicClient = usePublicClient();

  // Wallets price from a stale estimate, and Arbitrum's base fee drifts upward
  // between estimating and landing — the transaction is then rejected outright
  // for being under base fee. In a game decided by whether your take lands
  // inside 60 seconds, that is not a cost question, it is a correctness one.
  // Four times base with a 0.1 gwei floor is still a fraction of a cent.
  const feeOverrides = useCallback(async () => {
    try {
      const block = await publicClient?.getBlock();
      const base = block?.baseFeePerGas;
      if (!base) return {}; // not EIP-1559: let the wallet decide
      const maxPriorityFeePerGas = 10_000_000n; // 0.01 gwei
      const floor = 100_000_000n; // 0.1 gwei
      const bumped = base * 4n + maxPriorityFeePerGas;
      return { maxFeePerGas: bumped > floor ? bumped : floor, maxPriorityFeePerGas };
    } catch {
      return {};
    }
  }, [publicClient]);
  const [pendingTx, setPendingTx] = useState<`0x${string}` | undefined>();
  const receipt = useWaitForTransactionReceipt({ hash: pendingTx });

  useEffect(() => {
    if (receipt.isSuccess) {
      setPendingTx(undefined);
      stateQ.refetch();
      pendingQ.refetch();
      refresh();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [receipt.isSuccess]);

  async function takeIt() {
    setUiError("");
    if (!isConnected) return doConnect();
    if (!st) return;
    // If the round is over, the next take opens the following one at the floor price.
    const targetRound = expired ? round + 1 : round;
    const targetPrice = expired ? START_PRICE : price;
    try {
      const hash = await writeContractAsync({
        abi: askAbi,
        address: ASK_ADDRESS,
        functionName: "take",
        args: [BigInt(targetRound)],
        value: targetPrice,
        ...(await feeOverrides()),
      });
      setPendingTx(hash);
    } catch (e) {
      // The UI copy is deliberately blunt; the real error still belongs in the
      // console, or a failure like this is undebuggable.
      console.error(e);
      setUiError(bluntError(e));
    }
  }

  async function settle() {
    setUiError("");
    if (!isConnected) return doConnect();
    try {
      const hash = await writeContractAsync({
        abi: askAbi,
        address: ASK_ADDRESS,
        functionName: "endRound",
        ...(await feeOverrides()),
      });
      setPendingTx(hash);
    } catch (e) {
      // The UI copy is deliberately blunt; the real error still belongs in the
      // console, or a failure like this is undebuggable.
      console.error(e);
      setUiError(bluntError(e));
    }
  }

  async function claim() {
    setUiError("");
    try {
      const hash = await writeContractAsync({
        abi: askAbi,
        address: ASK_ADDRESS,
        functionName: "claimPending",
        ...(await feeOverrides()),
      });
      setPendingTx(hash);
    } catch (e) {
      // The UI copy is deliberately blunt; the real error still belongs in the
      // console, or a failure like this is undebuggable.
      console.error(e);
      setUiError(bluntError(e));
    }
  }

  const maxPrice = useMemo(
    () => chain.reduce((m, t) => (BigInt(t.price) > m ? BigInt(t.price) : m), 1n),
    [chain]
  );

  // Colour discipline: --fill when you're about to be paid, --cut when the pot
  // is about to go to somebody else.
  const closing = roundLive && left <= 15;
  const clockClass =
    "clock" + (!roundLive ? " idle" : iAmHolding && closing ? " win" : closing ? " cut" : "");

  return (
    <div className="wrap">
      <header className="topbar">
        <span className="brand">
          <span className="head">ASK</span>
          <a
            className="xlink"
            href="https://x.com/AskonRH"
            target="_blank"
            rel="noopener noreferrer"
            title="@AskonRH on X"
          >
            <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
              <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
            </svg>
            <span className="sr">@AskonRH on X</span>
          </a>
        </span>
        <span className="topright">
          <span className="lb">
            round <span className="hi">{round || "—"}</span>
            {"   "}pot <span className="hi">{fmtEth(pot)} Ξ</span>
            {"   "}hands <span className="hi">{hops}</span>
          </span>
          {isConnected && address && (
            <button className="linkbtn" onClick={() => disconnect()} title={address}>
              {shortAddr(address)} · disconnect
            </button>
          )}
        </span>
      </header>

      {mounted && pending > 0n && (
        <div className="banner">
          <span>
            You have <span className="won">{fmtEth(pending)} Ξ</span> unclaimed. A payout could not be pushed to you.
          </span>
          <button onClick={claim} disabled={!!pendingTx}>
            Claim
          </button>
        </div>
      )}

      <section className="hero">
        {!roundLive ? (
          <>
            <div className="clock idle">{expired ? "OVER" : "OPEN"}</div>
            <div className="lb">
              {expired
                ? "the clock ran out. settle it, then a new round opens."
                : `no one is holding. the opening ask costs ${fmtEth(START_PRICE)} Ξ.`}
            </div>
          </>
        ) : (
          <>
            <div className={clockClass}>{left.toFixed(1)}</div>
            <div className="lb">
              {iAmHolding ? "seconds until the pot is yours" : "seconds until the holder takes the pot"}
            </div>
          </>
        )}

        <div className="prize">
          {roundLive ? (
            iAmHolding ? (
              <span>
                You are holding. Hit zero and you take <span className="won">{fmtEth(winnerTake)} Ξ</span>. Get taken
                out and you leave with {fmtEth(exitValue)} Ξ — a 5% profit.
              </span>
            ) : (
              <span>
                {shortAddr(holder)} has held for {fmtDuration(heldSeconds)} and takes{" "}
                <span className="hi">{fmtEth(winnerTake)} Ξ</span> if nobody stops them.
              </span>
            )
          ) : (
            <span>the pot carries over. take it and start the next round.</span>
          )}
        </div>

        <div className="takerow">
          {wrongNetwork ? (
            <button className="take" onClick={switchNet} disabled={switching}>
              {switching ? "Switching…" : `Switch to ${CHAIN_NAME}`}
            </button>
          ) : expired ? (
            <button className="take" onClick={settle} disabled={!!pendingTx}>
              {pendingTx ? "Confirming…" : "Settle round"}
            </button>
          ) : (
            <button className="take" onClick={takeIt} disabled={!!pendingTx || iAmHolding}>
              {pendingTx
                ? "Confirming…"
                : iAmHolding
                  ? "You hold it"
                  : isConnected
                    ? `Take it — ${fmtEth(price)} Ξ`
                    : "Connect"}
            </button>
          )}
          {wrongNetwork ? (
            <span className="lb">your wallet is on another network. nothing here will work until you switch.</span>
          ) : (
            !iAmHolding &&
            roundLive && (
              <span className="lb">
                +{TIMER_BONUS}s on the clock · {shortAddr(holder)} is paid out at +5%
              </span>
            )
          )}
        </div>

        {picking && (
          <div className="picker">
            <div className="lb pickhead">choose a wallet</div>
            {wallets.map((c) => (
              <button key={c.uid} className="wrow" onClick={() => attempt(c)}>
                <span>{c.name}</span>
                <span className="tag">connect</span>
              </button>
            ))}
            <button className="wrow cancel" onClick={() => setPicking(false)}>
              <span>cancel</span>
            </button>
          </div>
        )}

        {uiError && <div className="err errline">{uiError}</div>}
      </section>

      <section>
        <div className="secthead">
          <span className="lb">the chain — round {round || "—"}</span>
          <span className="lb">
            {chain.length} {chain.length === 1 ? "hand" : "hands"}
          </span>
        </div>
        <div className="rows">
          {chain.map((t) => {
            const isCurrent = t.hop === hops && roundLive;
            const w = 4 + Number((BigInt(t.price) * 52n) / maxPrice);
            const mine = !!address && t.taker.toLowerCase() === address.toLowerCase();
            const profit = BigInt(t.flipped_return || "0");
            return (
              <div
                key={t.hop}
                className={"row" + (isCurrent ? " holding" : " outrow") + (flashHop === t.hop ? " flash" : "")}
              >
                <div className="bar" style={{ width: `${w}%` }} />
                <span className="cell dim">#{t.hop}</span>
                <span className="cell">
                  {shortAddr(t.taker)}
                  {mine ? " ← YOU" : ""}
                </span>
                <span className="cell num">{fmtEth(t.price)} Ξ</span>
                <span className="cell num">
                  {isCurrent ? (
                    <span className={closing ? (iAmHolding ? "won" : "err") : "hi"}>holding</span>
                  ) : profit > 0n ? (
                    <span className="won">out +5%</span>
                  ) : (
                    <span className="dim">opened</span>
                  )}
                </span>
                <span className="cell num dim">{isCurrent ? fmtDuration(heldSeconds) : fmtDuration(heldOf(chain, t))}</span>
              </div>
            );
          })}
          {chain.length === 0 && (
            <div className="row">
              <span className="cell lb">nobody has taken it yet.</span>
            </div>
          )}
        </div>
      </section>

      <section>
        <div className="secthead">
          <span className="lb">took the pot</span>
          <span className="lb">one per round</span>
        </div>
        <div className="rows">
          {winners.map((w) => (
            <div key={w.round_id} className="row outrow">
              <span className="cell dim">r{w.round_id}</span>
              <span className="cell">{shortAddr(w.winner)}</span>
              <span className="cell num won">+{fmtEth(w.won)} Ξ</span>
              <span className="cell num dim">{w.hops} hands</span>
              <span className="cell num dim">{timeAgo(w.ts)}</span>
            </div>
          ))}
          {winners.length === 0 && (
            <div className="row">
              <span className="cell lb">no round has ended yet.</span>
            </div>
          )}
        </div>
      </section>

      <section className="rules">
        <div className="lb">how it works</div>
        <p>
          Each ask costs 10% more than the one before it. When you take it, the holder before you is paid back 105% of
          what they paid — they leave with a 5% profit, immediately. The other 5% goes into the pot, the clock gains{" "}
          {TIMER_BONUS} seconds, and you are the one holding.
        </p>
        <p className="strong">
          The clock never goes above {TIMER_MAX} seconds, so it drains unless people keep taking. Whoever is holding
          when it reaches zero takes half the pot. There is no withdraw: your only exits are being taken out at +5%, or
          holding to zero.
        </p>
        <p className="dim">
          At the end of a round the pot splits 50% to the holder, 10% to the developers, and 40% into the next round —
          so the next pot never starts empty. The contract has no pause, no upgrade, and no owner powers beyond
          withdrawing that fee.
        </p>
        <div className="lb foot">
          contract {ASK_ADDRESS === ZERO ? "not configured" : shortAddr(ASK_ADDRESS)} · verified source · immutable
        </div>
      </section>
    </div>
  );
}

/** How long this hand ended up holding: the next take records it. */
function heldOf(chain: Take[], t: Take): number {
  const next = chain.find((x) => x.hop === t.hop + 1);
  return next ? next.held_seconds : 0;
}
