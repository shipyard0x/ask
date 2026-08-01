# ASK

Hold it when the clock stops. Robinhood Chain (Arbitrum Orbit L2).

Rounds. The opening ask costs 0.005 ETH. Every ask after that costs 10% more. When you take it: the holder before you is paid back **105% of what they paid** (they leave +5%, immediately), the other **5% goes into the pot**, and the clock gains **5 seconds** — capped at 60, so it drains unless people keep taking.

Whoever is holding when the clock hits zero takes **50% of the pot**. 10% goes to the devs, 40% seeds the next round.

Everyone taken out makes a small certain 5%. The one still holding at zero takes the pile. **Read "The last holder pays" below before you assume that pile is worth having** — measured against the current constants, it is not.

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

No proxy, no pause, no parameter setters. There is no `receive()` either: the contract rejects plain ETH, so the pot cannot be seeded from outside. The only privileged action is `withdrawDevFees`.

## Live deployment

| | |
|---|---|
| Network | Arbitrum Sepolia (chain id `421614`) — **testnet** |
| Contract | [`0x5adc4553364D098Cfff4754E2b2Af5d931f8fEc2`](https://sepolia.arbiscan.io/address/0x5adc4553364D098Cfff4754E2b2Af5d931f8fEc2) |
| Source | Verified on Sourcify, `exact_match` |
| Frontend | https://ask-blue.vercel.app |

Robinhood Chain is the intended target and has not been deployed to yet. Arbitrum Sepolia is a rehearsal.

## Layout

```
/contracts
  src/Ask.sol            the game
  src/legacy/            the original order-book version of ASK — not deployed
  test/Ask.t.sol         24 tests
  test/legacy/           37 tests for the order book, still green
  script/Deploy.s.sol    deploy script
  lib/                   vendored forge-std + 4 OpenZeppelin files (builds offline)
/bots/indexer            TypeScript + viem + node:sqlite. Event mirror, REST + SSE.
/web                     Next.js 14 app router, wagmi v2, PHOSPHOR theme. One page.
/ui-mock/index.html      standalone playable mock, no toolchain, no wallet
HANDOFF.md               what to run and what's left
```

## Running the stack locally

```sh
# 1 — chain. --block-time matters: with on-demand mining the chain clock
#     freezes between transactions and the UI clock has nothing to track.
anvil --block-time 1

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
| `forge test` | **Run. 61/61 pass** — 24 for the game (incl. a 50-op fuzz), 37 for the legacy order book. |
| Economics | **Verified in tests to the wei**, and again against the live testnet deployment: 32/32 checks re-deriving every payout from first principles. |
| Clock | **Verified on a real chain** from `Taken` event deadlines: opener gets 60s, every later take adds exactly 5s. A take landing with 2s left produced 7s, not 60. |
| Balance identity | **Asserted after every operation** in tests, and confirmed live: `address(this).balance == pot + devFees + totalPending`, with `totalPending == 0` (no payout ever needed the pull fallback). |
| Indexer | **Run end-to-end** against anvil and against Arbitrum Sepolia. |
| Web `next build` | **Run, passes.** Type-checked against real wagmi v2 / viem types. |
| Web in a browser | **Played by a human** on Arbitrum Sepolia: connect, take, flip, expiry, settle, payout. |
| Deploy | **Run on Arbitrum Sepolia**, source verified. Robinhood Chain not yet. |
| Audit | **Not done.** Still the blocker before real money. |

`/ui-mock/index.html` is the honest visual reference: open it in any browser, no install, and the whole game loop runs on simulated data.

## The last holder pays

Worth stating plainly, because the summary above reads the other way round.

Each take adds `1 − 1.05/1.1` ≈ **4.5%** of its price to the pot, while the price itself climbs **10%** per hand. The pot therefore converges to roughly **half the last price**, and the winner's 50% share lands near **a quarter of what they paid**.

Measured against the live deployment, round 2: the winner paid 0.006655 and received 0.00391375 — a **loss of 0.00274**. This is not an edge case. It holds for every chain length, and gets worse as the chain grows:

```
carry-in 0.002        hands   winner paid   winner gets      net
                          2     0.005500      0.003625    -0.001875
                          4     0.006655      0.003914    -0.002741
                          8     0.009744      0.004686    -0.005058
                         20     0.030580      0.009895    -0.020685
```

It cannot be tuned away by raising the winner's share. The game is a closed system: total in equals total out, minus the 10% dev fee. If every flipped holder is guaranteed +5%, the last holder is structurally the one funding it.

So the real game is **get flipped, don't be last**, and the "prize" is a partial refund. That may be the game you want — musical chairs is a fine game — but the contract as deployed does not pay the last holder more than they put in. See HANDOFF.md §4 for the options.

## Design notes

- **The clock adds, it does not reset.** A reset-to-60 clock can be held open forever by one player taking every 59 seconds. Adding 5s with a 60s cap means sustained activity is required to keep a round alive, and a busy round still ends.
- **The opener gets the full 60s.** Giving the first taker +5s on an empty clock would leave them five seconds to find a taker.
- **Two humans cannot keep a round alive.** Measured on testnet, each hand held 17–27 seconds while a take only buys 5. Round 2 died in 88 seconds despite four hands. Sustaining a round needs genuine concurrency — or a bot.
- **Colour is rationed and directional.** `--cut` red fires only when the pot is about to go to somebody else; `--fill` bone white only when money is coming to you. Anything coloured on screen is about your position.
- **Everyone paid out fades to ghost.** In the chain list, ghost means safe and done at +5%; the single amber row is the live holder — the only one who can still win or lose.

## Known trade-offs

- **The last holder pays.** See above. The single most important open design question.
- **Bots have an edge at 60 seconds.** A script watching the mempool can take at the last moment, every time. Given two humans provably cannot sustain a round, a bot that can is a structural advantage, not just a fast finger. See HANDOFF.md §4.
- **Wallets underprice gas on L2s.** Arbitrum's base fee drifts and wallet estimates lag it, producing `max fee per gas less than block base fee`. In a game decided by whether your transaction lands inside 60 seconds this is a correctness problem, not a cost one. The frontend now sets its own fees; the contract cannot help here.
- **The reorg path is untested.** The indexer tracks block hashes and rolls back on mismatch, but no real reorg was ever forced against it.
