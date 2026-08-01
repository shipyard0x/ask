# ASK

Hold it when the clock stops. Robinhood Chain (Arbitrum Orbit L2).

Rounds. The opening ask costs 0.005 ETH. Every ask after that costs 10% more. When you take it: the holder before you is paid back **105% of what they paid** (they leave +5%, immediately), the other **5% goes into the pot**, and the clock gains **5 seconds** — capped at 60, so it drains unless people keep taking.

Whoever is holding when the clock hits zero takes **50% of the pot**. 10% goes to the devs, 40% seeds the next round.

Everyone taken out makes a small certain 5%. The one still holding at zero takes the pile. That's the trade.

## The game — `contracts/src/Ask.sol`

| | |
|---|---|
| Opening ask | 0.005 ETH (gets the full 60s clock) |
| Each next ask | +10% |
| Paid to the holder you take from | 105% of their cost (+5% profit) |
| Skimmed to the pot | the remaining 5% of the step |
| Clock | +5s per take, hard cap 60s |
| Round end | holder takes 50% of pot · devs 10% · next round 40% |
| Exits | taken out at +5%, or hold to zero. No withdraw, no cancel. |

`take(expectedRound)` carries the round you mean to join, so if the clock runs out between signing and landing you revert instead of opening a fresh round at a stale price. Finished rounds settle lazily on the next take, or via a public `endRound()` anyone can call.

Payouts push with 30k gas and fall back to `pendingWithdrawals` + `claimPending()`, so no contract can stall the game — including a contract that wins.

No proxy, no pause, no parameter setters. The only privileged action is `withdrawDevFees`.

## Layout

```
/contracts
  src/Ask.sol            the game
  src/legacy/            the original order-book version of ASK — not deployed
  test/Ask.t.sol         24 tests
  test/legacy/           37 tests for the order book, still green
  script/Deploy.s.sol    Robinhood Chain deploy
  lib/                   vendored forge-std + 3 OpenZeppelin files (builds offline)
/bots/indexer            TypeScript + viem + node:sqlite. Event mirror, REST + SSE.
/web                     Next.js 14 app router, wagmi v2, PHOSPHOR theme. One page.
/ui-mock/index.html      standalone playable mock, no toolchain, no wallet
HANDOFF.md               what to run and what's left
```

## Running the stack locally

```sh
# 1 — chain
anvil

# 2 — deploy
cd contracts
export PRIVATE_KEY=<anvil key 0>
forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast

# 3 — indexer
cd bots/indexer && npm install
RPC_URL=http://127.0.0.1:8545 ASK_ADDRESS=<deployed> npm start
#   GET /state /chain /rounds /events /player/:addr
#   GET /stream   (SSE: per-event pushes + 15s state snapshots)

# 4 — web
cd web && npm install && cp .env.example .env.local   # set NEXT_PUBLIC_ASK_ADDRESS
npm run dev
```

Regenerate the indexer ABI after any contract change:

```sh
node -e "const a=require('./contracts/out/Ask.sol/Ask.json').abi;\
require('fs').writeFileSync('./bots/indexer/src/abi.ts','export const askAbi = '+JSON.stringify(a,null,1)+' as const;\n')"
```

## Verification — what was actually run, and what wasn't

| Piece | Status |
|---|---|
| `forge test` | **Run. 61/61 pass** — 24 for the game (incl. a 50-op fuzz), 37 for the legacy order book. Output in `contracts/forge-test-output.txt`. |
| Economics | **Verified in tests to the wei**: flipped holders receive exactly 105% of their cost; the pot grows by exactly 5% of each price; the round-end split is exactly 50/10/40; `winnerTake()` and `holderExitValue()` quote the real payouts. |
| Clock | **Verified**: a take adds 5s rather than resetting, the clock hard-caps at 60s under rapid-fire takes, and it genuinely drains to zero when takes slow down. |
| Balance identity | **Asserted after every operation** in every test and throughout the fuzz: `address(this).balance == pot + devFees + totalPending`. |
| Indexer | **Run end-to-end** against anvil: a 4-hand chain with takes 8s apart, then the clock ran out. Clock drained 60 → 57 → 53 → 50, price ladder 0.005 → 0.0055 → 0.00605 → 0.006655, each flip paid exactly 105%, pot grew by exactly 5% each hand, the winner's balance delta matched `winnerTake()` to the wei, and the 50/10/40 split landed correctly in `/rounds`. |
| Web `next build` | **Not run.** The build environment could not finish `npm install` for the Next + wagmi tree inside its per-command time limit. The web sources pass an esbuild parse check but have **not** been type-checked against real wagmi/viem types or rendered in a browser. |
| Deploy | **Not run.** No funded key. Script and verify commands are ready. |
| Audit | **Not done.** |

`/ui-mock/index.html` is the honest visual reference: open it in any browser, no install, and the whole game loop runs on simulated data.

## Design notes

- **The clock adds, it does not reset.** A reset-to-60 clock can be held open forever by one player taking every 59 seconds. Adding 5s with a 60s cap means sustained activity is required to keep a round alive, and a busy round still ends.
- **The opener gets the full 60s.** Giving the first taker +5s on an empty clock would leave them five seconds to find a taker.
- **A solo round is a loss.** Open a round and win it alone and you take back 50% of a pot that is just your own opening ask. Someone has to take it from you for the trade to work.
- **Colour is rationed and directional.** `--cut` red fires only when the pot is about to go to somebody else; `--fill` bone white only when money is coming to you. Anything coloured on screen is about your position.
- **Everyone paid out fades to ghost.** In the chain list, ghost means safe and done at +5%; the single amber row is the live holder — the only one who can still win or lose.

## Known trade-offs

- **Bots have an edge at 60 seconds.** A script watching the mempool can take at the last moment, every time. Whether that's a feature (it is a latency game) or a problem is a product decision — see HANDOFF.md §4.
- **The reorg path is untested.** The indexer tracks block hashes and rolls back on mismatch, but no real reorg was ever forced against it.
