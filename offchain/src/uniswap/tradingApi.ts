// Uniswap Trading API client (per the uniswap-ai `swap-integration` skill v1.6.0).
// Flow: POST /check_approval -> POST /quote -> POST /swap. API key from env only; never hard-coded.
import { isAddress, isHex, type Hex, type PrivateKeyAccount } from "viem";

export const TRADING_API = "https://trade-api.gateway.uniswap.org/v1";
export const NATIVE = "0x0000000000000000000000000000000000000000";

const ADDRESS_RE = /^0x[a-fA-F0-9]{40}$/;
const AMOUNT_RE = /^[0-9]+$/; // base units (wei) only

export type TradeType = "EXACT_INPUT" | "EXACT_OUTPUT";
export type DecisionOrigin = "human_mediated" | "autonomous";

export interface QuoteRequest {
  swapper: string;
  tokenIn: string;
  tokenOut: string;
  chainId: number;
  amount: string; // base units
  type: TradeType;
  slippageTolerance?: number; // percent, 0-100
}

function headers(origin: DecisionOrigin): Record<string, string> {
  const key = process.env.UNISWAP_API_KEY;
  if (!key) throw new Error("UNISWAP_API_KEY is not set (put it in .env)");
  return {
    "Content-Type": "application/json",
    "x-api-key": key,
    "x-universal-router-version": "2.0",
    "x-agent-info": JSON.stringify({ integration_name: "swap-integration", decision_origin: origin, version: "1.6.0" }),
  };
}

function validate(req: QuoteRequest) {
  for (const [k, v] of [["swapper", req.swapper], ["tokenIn", req.tokenIn], ["tokenOut", req.tokenOut]] as const) {
    if (!ADDRESS_RE.test(v)) throw new Error(`invalid ${k}: ${v}`);
  }
  if (!AMOUNT_RE.test(req.amount) || req.amount === "0") throw new Error(`invalid amount: ${req.amount}`);
  if (!Number.isInteger(req.chainId) || req.chainId <= 0) throw new Error(`invalid chainId: ${req.chainId}`);
  const s = req.slippageTolerance ?? 0.5;
  if (!(s >= 0 && s <= 100)) throw new Error(`invalid slippage: ${s}`);
}

async function post<T>(path: string, body: unknown, origin: DecisionOrigin): Promise<T> {
  const res = await fetch(`${TRADING_API}${path}`, { method: "POST", headers: headers(origin), body: JSON.stringify(body) });
  const json: any = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`Trading API ${path} ${res.status}: ${json.errorCode ?? ""} ${json.detail ?? ""}`.trim());
  return json as T;
}

export interface TxRequest {
  to: Hex;
  from: Hex;
  data: Hex;
  value: string;
  chainId: number;
  gasLimit?: string;
}

export async function checkApproval(wallet: string, token: string, amount: string, chainId: number, origin: DecisionOrigin = "human_mediated") {
  if (token === NATIVE) return null; // native ETH needs no approval
  const r = await post<{ approval: TxRequest | null }>("/check_approval", { walletAddress: wallet, token, amount, chainId }, origin);
  return r.approval;
}

export async function quote(req: QuoteRequest, origin: DecisionOrigin = "human_mediated"): Promise<any> {
  validate(req);
  return post("/quote", {
    swapper: req.swapper,
    tokenIn: req.tokenIn,
    tokenOut: req.tokenOut,
    tokenInChainId: String(req.chainId),
    tokenOutChainId: String(req.chainId),
    amount: req.amount,
    type: req.type,
    slippageTolerance: req.slippageTolerance ?? 0.5,
    routingPreference: "BEST_PRICE",
    protocols: ["V2", "V3", "V4"], // on-chain AMM routes only (CLASSIC); no UniswapX orders for treasury ops
  }, origin);
}

/** Build the /swap body: spread the quote, strip permit fields, re-attach signature+permitData only together. */
export async function prepareSwap(quoteResponse: any, account?: PrivateKeyAccount): Promise<Record<string, unknown>> {
  const { permitData, permitTransaction, ...clean } = quoteResponse;
  const body: Record<string, unknown> = { ...clean };
  if (quoteResponse.routing !== "CLASSIC" && quoteResponse.routing !== "WRAP" && quoteResponse.routing !== "UNWRAP") {
    throw new Error(`unsupported routing ${quoteResponse.routing} for treasury operations`);
  }
  if (permitData && typeof permitData === "object") {
    if (!account) throw new Error("quote requires a Permit2 signature but no signer was provided");
    const signature = await account.signTypedData({
      domain: permitData.domain,
      types: permitData.types,
      primaryType: Object.keys(permitData.types).find((t) => t !== "EIP712Domain")!,
      message: permitData.values,
    });
    body.signature = signature;
    body.permitData = permitData;
  }
  return body;
}

export async function swap(swapBody: Record<string, unknown>, origin: DecisionOrigin = "human_mediated"): Promise<TxRequest> {
  const r = await post<{ swap: TxRequest }>("/swap", swapBody, origin);
  validateBeforeBroadcast(r.swap);
  return r.swap;
}

/** Skill rule 4: never broadcast an empty / malformed transaction. */
export function validateBeforeBroadcast(tx: TxRequest) {
  if (!tx?.data || tx.data === "0x") throw new Error("swap.data is empty - quote likely expired; re-fetch");
  if (!isHex(tx.data)) throw new Error("swap.data is not valid hex");
  if (!isAddress(tx.to)) throw new Error("swap.to is not a valid address");
  if (!isAddress(tx.from)) throw new Error("swap.from is not a valid address");
  if (tx.value === undefined || tx.value === null) throw new Error("swap.value is missing");
}

/** Indicative USD value of `amount` of `token` via a USDC quote (6 decimals). */
export async function usdValue(token: string, amount: string, chainId: number, usdc: string, swapper: string): Promise<number | null> {
  try {
    const q = await quote({ swapper, tokenIn: token, tokenOut: usdc, chainId, amount, type: "EXACT_INPUT" });
    const out = q?.quote?.output?.amount;
    return out ? Number(out) / 1e6 : null;
  } catch {
    return null;
  }
}
