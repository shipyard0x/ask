# ASK — handoff

Everything you need to pick this up in VS Code. Read `README.md` for what the game is; this file is only about what to run and what's left.

---

## 0. What state the project is in

| Piece | State |
|---|---|
| `contracts/src/Ask.sol` | Done. 24 tests, all passing. Deployed to Arbitrum Sepolia, source verified. |
| `contracts/src/legacy/OrderBook.sol` | The original order-book game. 37 tests passing. Not deployed. Keep or delete. |
| `bots/indexer` | Done. Verified against a local chain and against Arbitrum Sepolia. Runs locally only — not hosted. |
| `web` | Builds, deployed, played by a human. https://ask-blue.vercel.app |
| Deploy | Arbitrum Sepolia only. **Robinhood Chain not done** — no RPC URL or chain id available yet. |
| Audit | Not done. Still the blocker before real money. |
| Economics | **Open question.** The last holder loses money by construction. See §4. |

`forge test` = 61/61 green. `next build` passes. 32/32 economic checks pass against the live deployment.

---

## 1. First commands, in order

```bash
# contracts — should be green immediately
cd contracts
forge build
forge test

# indexer deps
cd ../bots/indexer
npm install

# web deps
cd ../../web
npm install
npm run build
```

If `forge build` complains about a solc path, open `contracts/foundry.toml` and delete the entire `[profile.sandbox]` block — it points at a path from the machine this was built on and is not needed.

**Never run `npm run build` while `npm run dev` is running.** They share `.next`, and the production build will overwrite the dev server's output mid-flight. The page then serves with no stylesheet attached and looks catastrophically broken. Stop dev, `rm -rf .next`, build, restart.

---

## 2. Running the whole thing locally

Four terminals.

```bash
# 1 — chain
anvil --block-time 1

# 2 — deploy (anvil prints its keys; account 0 is fine)
cd contracts
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast
# copy the printed address

# 3 — indexer
cd bots/indexer
RPC_URL=http://127.0.0.1:8545 ASK_ADDRESS=<paste address> npm start

# 4 — web
cd web
cp .env.example .env.local     # set NEXT_PUBLIC_ASK_ADDRESS to the same address
npm run dev                    # http://localhost:3000
```

Point MetaMask at `http://127.0.0.1:8545`, chain id `31337`, and import an anvil key.

`--block-time 1` is not optional in practice. Plain `anvil` only mines when a transaction arrives, so `block.timestamp` freezes between takes, `state()` returns a stale clock, and the UI re-anchors to the same number every two seconds.

**Regenerate the indexer ABI** whenever you change `Ask.sol`:

```bash
node -e "const a=require('./contracts/out/Ask.sol/Ask.json').abi;require('fs').writeFileSync('./bots/indexer/src/abi.ts','export const askAbi = '+JSON.stringify(a,null,1)+' as const;\n')"
```

A stale ABI fails silently on a real network — events simply never arrive and the chain list stays empty with no error.

---

## 3. Testnet deployment

Live on Arbitrum Sepolia. Chosen because Robinhood Chain is an Arbitrum Orbit L2, so it is the closest public analogue, and because its sub-second blocks matter: on a 12-second chain like Sepolia L1 a take adds 5s while a block costs 12s, so a round cannot be sustained at all.

```
contract   0x5adc4553364D098Cfff4754E2b2Af5d931f8fEc2
chain id   421614
rpc        https://sepolia-rollup.arbitrum.io/rpc
frontend   https://ask-blue.vercel.app
source     verified on Sourcify (exact_match) — no API key needed
```

Deploying elsewhere:

```bash
export PRIVATE_KEY=<a key generated somewhere secure>
cast block-number --rpc-url <rpc>          # note this for START_BLOCK
forge script script/Deploy.s.sol:Deploy --rpc-url <rpc> --broadcast
forge verify-contract <address> src/Ask.sol:Ask --chain-id <id> --verifier sourcify --watch
```

`START_BLOCK` is mandatory for the indexer on any real chain. It defaults to 0 and scans 500 blocks per one-second tick; Arbitrum Sepolia is past 293,000,000 blocks, which is roughly 55 hours of catch-up before anything renders.

---

## 4. What's actually left, in priority order

### P0 — decide before anything else is built on top

1. **The last holder pays.** Each take skims ~4.5% of its price into the pot while the price climbs 10%. The pot converges to about half the last price, so the winner's 50% share is about a quarter of what they paid. Verified against the live deployment: the round 2 winner paid 0.006655 and received 0.00391375. It is not an edge case and it worsens with chain length.

   It cannot be fixed by raising the winner's share — the game is closed-sum minus the dev fee, so guaranteeing every flipped holder +5% means the last holder funds it. The options are genuinely different games:

   - **Accept it.** Rebrand honestly as musical chairs: *get flipped, don't be last*. No contract change. The current README section says this plainly.
   - **Drop the guaranteed +5%.** Pay flipped holders exactly their cost back and skim the whole 10% step. The pot then grows fast enough for the winner to profit, but you lose the "small certain gain" that makes taking attractive.
   - **Flatten the price curve.** A smaller step means the winner's cost compounds slower. Changes the feel completely.
   - **Fund the prize externally.** A treasury or sponsor tops up the pot. Note the contract has no `receive()`, so this needs a v2 or a satellite contract that pays the winner directly.

   All but the first are a new contract plus tests.

2. **Audit `Ask.sol`.** I wrote both the contract and its tests, which means the tests encode my assumptions. It holds real ETH with no pause, no upgrade, and no withdraw. Point an auditor at the lazy-settle path inside `take()`, the `expectedRound` guard, and the push/pull payout fallback.

### P1 — before Robinhood Chain

3. **Robinhood Chain deploy.** Needs the RPC URL and chain id, neither of which is in this repo — `foundry.toml` just has `${ROBINHOOD_RPC_URL}`. Also needs a deployer key generated somewhere secure: whoever deploys becomes the permanent `owner` and controls `withdrawDevFees`.
4. **Host the indexer.** `NEXT_PUBLIC_INDEXER_URL` on the live site still points at `127.0.0.1:8747`, so "the chain" and "took the pot" are permanently empty for every visitor. Needs Node 20+ and a persistent disk for `node:sqlite`, or history wipes on restart. The frontend degrades gracefully, so this breaks nothing — it just shows no history, ever.
5. **Wallet reputation pre-flight.** Verify source at deploy time, and submit the address to Blockaid and MetaMask for review before announcing. A contract that takes ETH with no withdraw has a shape heuristic scanners dislike. Cheaper to learn this on a testnet than on launch day.
6. **Consider setting gas explicitly for Robinhood Chain.** The frontend now computes `maxFeePerGas` as 4× base fee with a 0.1 gwei floor, because wallets underprice on L2s and a take that does not land inside 60 seconds is a lost round. Confirm those numbers make sense on Robinhood Chain before launch.

### P2 — missing features

7. **No player page.** The indexer serves `/player/:addr` (takes, wins, times flipped). Nothing consumes it. A "your record: 14 hands, 2 pots taken, +0.31 Ξ" line would be strong.
8. **No sound.** A latency game with a draining clock wants an audio cue in the last 10 seconds. Optional, off by default, but it changes how the game feels.
9. **The winner is never notified.** A browser notification on `RoundWon` where `winner == you` would close the loop.
10. **No mobile wallets.** EIP-6963 discovery covers desktop extensions only. WalletConnect needs the `@wagmi/connectors` barrel, which currently fails to resolve `@x402/*`, plus a projectId.
11. **The reorg path is untested.** `bots/indexer/src/index.ts` tracks block hashes and rolls back on mismatch, but no real reorg was ever forced. Test with `anvil` snapshot/revert.

### P3 — design questions, not bugs

12. **Bots have the edge at 60 seconds.** Measured on testnet, two humans cannot keep a round alive: each hand held 17–27 seconds while a take buys 5. A bot taking every few seconds can hold a round open indefinitely, which makes this a structural advantage rather than a fast finger. Options: raise `TIMER_BONUS`, jitter the deadline, or require a minimum hold. All are contract changes plus tests.
13. **Decide the legacy order book's fate.** `contracts/src/legacy/` and `contracts/test/legacy/` are a complete, tested, unused game. Delete it or keep it as a second mode.
14. **Gas-optimise `take()`.** In a latency race, cheaper is faster to land.

---

## 5. Things that will trip you up

- **`ui-mock/index.html` is not the app.** It's a standalone simulation of the design with fake data, no wallet, no chain. Useful for showing people the look; don't confuse it with `/web`.
- **`take()` requires an exact `msg.value`.** If someone takes it before your transaction lands, the price has moved and yours reverts with `WrongPrice`. That is the intended behaviour — the UI already translates it to "Someone took it first. The price moved."
- **`contracts/lib/` is vendored on purpose** (forge-std + four OpenZeppelin files) so the repo builds offline. Don't `forge install` over it, and don't let `lib/forge-std` become a nested git repo again — it was committed once as a bare gitlink, which gives anyone cloning an empty directory and a build that fails on the first command in this file.
- **The indexer needs Node 20+** — it uses the built-in `node:sqlite`, no native dependency.
- **`0x5FbDB2315678afecb367f032d93F642f64180aa3` is blocklisted.** That's `CREATE(anvil account 0, nonce 0)` — the address every hardhat and anvil project's first deploy lands on. Anvil's key is public, so scammers have deployed drainers there on real chains, and MetaMask shows a full-page "deceptive request" warning by address alone, even on chain 31337. Deploy from a random key if you want to demo locally without that.
- **`vercel env add` from PowerShell corrupts values.** PowerShell 5.1 prepends a UTF-8 BOM when piping to a native command's stdin, so every variable arrives as `﻿<value>`. `NEXT_PUBLIC_ASK_ADDRESS` then isn't a valid address and every contract read fails silently. Use bash with `printf '%s'`, or the dashboard.
- **Wallet-dependent UI must wait for mount.** The server renders with no wallet and the browser reconnects before React hydrates. Rendering a connected-only element on the first client pass throws away the whole server tree — which on a page with a 100ms clock is a visible stutter. `page.tsx` gates `isConnected` behind a `mounted` flag for this reason.
