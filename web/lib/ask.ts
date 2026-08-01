import { defineChain } from "viem";
// `injected` comes from wagmi's own entry (re-exported from @wagmi/core), not
// from "wagmi/connectors" — that barrel pulls in the Base/Coinbase account SDKs
// and their optional @x402/* deps, which we neither install nor use.
import { createConfig, http, injected } from "wagmi";

export const ASK_ADDRESS = (process.env.NEXT_PUBLIC_ASK_ADDRESS ??
  "0x0000000000000000000000000000000000000000") as `0x${string}`;
export const INDEXER_URL = process.env.NEXT_PUBLIC_INDEXER_URL ?? "http://127.0.0.1:8747";
export const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL ?? "http://127.0.0.1:8545";
export const CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? 31337);
/** Shown when we have to ask someone to switch networks. */
export const CHAIN_NAME = process.env.NEXT_PUBLIC_CHAIN_NAME ?? "Robinhood Chain";

export const robinhoodChain = defineChain({
  id: CHAIN_ID,
  name: CHAIN_NAME,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
});

export const wagmiConfig = createConfig({
  chains: [robinhoodChain],
  // EIP-6963. Every installed wallet announces itself, so MetaMask, Phantom,
  // Rabby, Coinbase, Brave and the rest arrive on their own — naming them here
  // would only be a list to keep out of date. `injected` stays as the fallback
  // for an older wallet that writes window.ethereum but never announces.
  multiInjectedProviderDiscovery: true,
  connectors: [injected()],
  transports: { [robinhoodChain.id]: http(RPC_URL) },
});

export const TIMER_MAX = 60;
export const TIMER_BONUS = 5;
export const START_PRICE = BigInt("5000000000000000"); // 0.005 ETH

export const askAbi = [
  {
    type: "function",
    name: "take",
    stateMutability: "payable",
    inputs: [{ name: "expectedRound", type: "uint256" }],
    outputs: [],
  },
  { type: "function", name: "endRound", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { type: "function", name: "claimPending", stateMutability: "nonpayable", inputs: [], outputs: [] },
  {
    type: "function",
    name: "state",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "round", type: "uint256" },
      { name: "currentPrice", type: "uint256" },
      { name: "currentHolder", type: "address" },
      { name: "currentHolderPaid", type: "uint256" },
      { name: "secondsLeft", type: "uint256" },
      { name: "heldSeconds", type: "uint256" },
      { name: "potWei", type: "uint256" },
      { name: "winnerTakeWei", type: "uint256" },
      { name: "hops", type: "uint64" },
      { name: "expired", type: "bool" },
    ],
  },
  {
    type: "function",
    name: "holderExitValue",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "pendingWithdrawals",
    stateMutability: "view",
    inputs: [{ name: "", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  { type: "error", name: "WrongPrice", inputs: [{ name: "sent", type: "uint256" }, { name: "required", type: "uint256" }] },
  { type: "error", name: "WrongRound", inputs: [{ name: "given", type: "uint256" }, { name: "current", type: "uint256" }] },
  { type: "error", name: "AlreadyHolding", inputs: [] },
  { type: "error", name: "RoundStillLive", inputs: [{ name: "secondsRemaining", type: "uint256" }] },
  { type: "error", name: "NoRoundToEnd", inputs: [] },
  { type: "error", name: "NothingPending", inputs: [] },
  { type: "error", name: "TransferFailed", inputs: [] },
] as const;

export function fmtEth(wei: bigint | string, dp = 5): string {
  const v = typeof wei === "string" ? BigInt(wei) : wei;
  return (Number(v) / 1e18).toLocaleString("en-US", {
    minimumFractionDigits: dp,
    maximumFractionDigits: dp,
  });
}

export function shortAddr(a: string): string {
  return a.slice(0, 4) + ".." + a.slice(-2);
}

export function fmtDuration(s: number): string {
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
  return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
}

export function timeAgo(ts: number): string {
  const s = Math.max(1, Math.floor(Date.now() / 1000 - ts));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86_400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86_400)}d ago`;
}

/** Blunt error copy. The house style: say what happened, no apology. */
export function bluntError(e: unknown): string {
  const s = String((e as Error)?.message ?? e ?? "");
  // Wrong network is the one failure a newcomer hits first, and it used to fall
  // through to the generic line — which told them nothing.
  if (s.includes("ChainMismatch") || s.includes("chain mismatch") || s.includes("does not match the target chain"))
    return `Wrong network. Switch to ${CHAIN_NAME}.`;
  if (s.includes("ChainNotConfigured") || s.includes("Chain not configured"))
    return `Wrong network. Switch to ${CHAIN_NAME}.`;
  if (s.includes("WrongPrice")) return "Someone took it first. The price moved.";
  if (s.includes("WrongRound")) return "That round is over. This one just opened.";
  if (s.includes("AlreadyHolding")) return "You are already holding it.";
  if (s.includes("RoundStillLive")) return "The clock is still running.";
  if (s.includes("NoRoundToEnd")) return "Nothing to settle.";
  if (s.includes("NothingPending")) return "You have nothing to claim.";
  if (s.includes("ProviderNotFound") || s.includes("Provider not found") || s.includes("ConnectorNotFound"))
    return "No wallet found. Install a browser wallet.";
  // Arbitrum's base fee drifts and wallets routinely price below it. In a game
  // decided by whether your transaction lands, this must not read as "failed".
  if (s.includes("less than block base fee") || s.includes("underpriced") || s.includes("fee cap"))
    return "Gas price too low. Raise the max fee in your wallet and retry.";
  if (s.includes("intrinsic gas too low")) return "Gas limit too low. Raise it in your wallet.";
  if (s.includes("insufficient funds")) return "Not enough ETH in your wallet.";
  if (s.includes("User rejected") || s.includes("user rejected")) return "You rejected the transaction.";
  return "Transaction failed.";
}
