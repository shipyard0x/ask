# ASK — handoff

Everything you need to pick this up in VS Code. Read `README.md` for what the game is; this file is only about what to run and what's left.

---

## 0. What state the project is in

| Piece | State |
|---|---|
| `contracts/src/Ask.sol` | Done. 24 tests, all passing. |
| `contracts/src/legacy/OrderBook.sol` | The original order-book game. 37 tests passing. Not deployed. Keep or delete. |
| `bots/indexer` | Done. Verified end-to-end against a local chain. |
| `web` | **Written but never built.** This is your first task. |
| Deploy | Not done. No funded key was available. |
| Audit | Not done. |

`forge test` = 61/61 green. `next build` has never once been run.

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

# web deps — THIS is where problems will show up
cd ../../web
npm install
npm run build
```

If `forge build` complains about a solc path, open `contracts/foundry.toml` and delete the entire `[profile.sandbox]` block — it points at a path from the machine this was built on and is not needed.

---

## 2. Running the whole thing locally

Four terminals.

```bash
# 1 — chain
anvil

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

**Regenerate the indexer ABI** whenever you change `Ask.sol`:

```bash
node -e "const a=require('./contracts/out/Ask.sol/Ask.json').abi;require('fs').writeFileSync('./bots/indexer/src/abi.ts','export const askAbi = '+JSON.stringify(a,null,1)+' as const;\n')"
```

---

## 3. Paste this into Claude in VS Code

> I'm working on ASK, an onchain game in this repo. Read `README.md` and `HANDOFF.md` first.
>
> The Solidity and the indexer are done and tested. The Next.js app in `/web` has never been built — it was written without a working toolchain, so it is syntactically valid but has not been type-checked against real wagmi v2 / viem types.
>
> Task one: get `cd web && npm install && npm run build` to pass. Fix type errors in place. Do not restructure the app, do not add a component library, do not change the visual design — the PHOSPHOR theme in `app/globals.css` is deliberate (one hue, zero border-radius, `--cut` red reserved for when the pot is about to go to someone else, `--fill` bone white reserved for money coming to you). The most likely problems are the `useReadContract` return-tuple typing in `app/page.tsx` (the `state()` view returns a 10-field tuple), and hook dependency arrays.
>
> Task two: run the full local stack per HANDOFF.md section 2 and confirm the clock ticks and adds 5s per take, taking works, and the chain-of-holders list updates.
>
> Then stop and show me what you changed. Don't start on the deploy.

---

## 4. What's actually left, in priority order

### P0 — blocking a demo

1. **Make `/web` build.** Expect type errors around `useReadContract` generics and the `state()` tuple destructuring in `app/page.tsx`. Nothing architectural.
2. **Play it locally.** Two browser profiles with two anvil accounts, take it back and forth, then let the clock run out. Watch that:
   - the clock ticks smoothly between the 2s chain reads, and **adds 5s** on a take rather than resetting to 60,
   - the clock goes **bone white** when *you* hold under 15s (you're about to be paid) and **red** when someone else holds under 15s (the pot is about to leave),
   - chain rows fade to ghost once a holder is paid out at +5%,
   - the win lands in the "took the pot" list with the right amount (50% of the pot),
   - the `Settle round` button appears once the clock is at zero.

### P1 — missing features I did not build

3. **No player page.** The indexer serves `/player/:addr` (takes, wins, times flipped). Nothing consumes it. A "your record: 14 hands, 2 pots taken, +0.31 Ξ" line would be strong.
4. **No sound.** A latency game with a draining clock wants an audio cue in the last 10 seconds. Optional, off by default, but it changes how the game feels.
5. **The winner is never notified.** If you win while the tab is backgrounded you find out by checking. A browser notification on `RoundWon` where `winner == you` would close that loop.

### P2 — before real money

6. **Get `Ask.sol` audited.** I wrote both the contract and its tests, which means the tests encode my assumptions. It holds real ETH with no pause, no upgrade, and no withdraw. Specific things to point an auditor at: the lazy-settle path inside `take()`, the `expectedRound` guard, and the push/pull payout fallback.
7. **Deploy + verify** on Robinhood Chain, then put the real address in `web/.env.local` and the footer.
8. **The reorg path is untested.** `bots/indexer/src/index.ts` tracks block hashes and rolls back on mismatch, but I never forced an actual reorg. Test it with `anvil` snapshot/revert before trusting it on a live chain.

### P3 — design questions, not bugs

9. **Bots have the edge at 60 seconds.** A script watching the mempool can always take at the last moment. Given the pot goes to whoever holds at zero, a bot can also snipe the win. Options if you want to blunt it: raise `TIMER_BONUS` so activity matters more than timing, add a small randomised jitter to the deadline, or require a minimum hold time before a take counts. All are contract changes plus tests.
10. **Decide the legacy order book's fate.** `contracts/src/legacy/` and `contracts/test/legacy/` are a complete, tested, unused game. Delete it or keep it as a second mode.
11. **Gas-optimise `take()`.** In a latency race, cheaper is faster to land. It's already small, but worth a look at the storage writes.

---

## 5. Things that will trip you up

- **`ui-mock/index.html` is not the app.** It's a standalone simulation of the design with fake data, no wallet, no chain. Useful for showing people the look; don't confuse it with `/web`.
- **`take()` requires an exact `msg.value`.** If someone takes it before your transaction lands, the price has moved and yours reverts with `WrongPrice`. That is the intended behaviour — the UI already translates it to "Someone took it first. The price moved."
- **`contracts/lib/` is vendored on purpose** (forge-std + two OpenZeppelin files) so the repo builds offline. Don't `forge install` over it.
- **The indexer needs Node 20+** — it uses the built-in `node:sqlite`, no native dependency.
