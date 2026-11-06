import { BaseError, ContractFunctionRevertedError, decodeErrorResult, type Abi } from "viem";
import { destinationReceiverAbi, nidhiDispatcherAbi, nidhiHookAbi, nidhiSwapRouterAbi, roleAuthorityAbi } from "../data/abi";

// One plain sentence per revert reason in src/ (NidhiHook, NidhiDispatcher, DestinationReceiver, RoleAuthority).
const PLAIN: Record<string, (a: readonly unknown[]) => string> = {
  Paused: () => "Grants are paused by the guardian.",
  CapExceeded: (a) => `This is more than today's cap allows. Left today: ${a[1]} wei.`,
  RecipientMismatch: () => "The grantee's registered address on that chain does not match the mandate.",
  WrongExecutor: () => "Only the executor named in the mandate can send this grant.",
  MandateExpired: () => "The mandate's deadline has passed. Sign a new one.",
  GrantAlreadyUsed: () => "This grant has already been sent.",
  BadSignature: () => "A signature does not match its signer.",
  SameSigner: () => "The approver and the auditor must be two different people.",
  NotAuthorized: () => "A signer does not hold the role this needs.",
  AttestationMismatch: () => "The audit attestation is for a different grant or evidence.",
  OutputOutOfBounds: () => "The swap output fell outside the mandate's band. Get a new quote.",
  PriceDeviation: () => "The pool price is too far from the reference pool. The swap was refused.",
  WrongPool: () => "The mandate points at a different pool.",
  UntrustedRouter: () => "Swaps must go through Nidhi's router.",
  NotExactInput: () => "The swap amount must equal the mandate amount.",
  WrongDirection: () => "The swap direction does not match the mandate's tokens.",
  InvalidMandate: () => "The mandate is incomplete.",
  InsufficientFee: () => "The contract's CCIP fee reserve is too low. Top it up.",
  NotConfigured: () => "No route to that chain is set up yet.",
  WrongDestination: () => "The mandate's receiver is not the one this chain routes to.",
  AccessControlUnauthorizedAccount: () => "Your wallet does not hold the role this needs.",
  OwnableUnauthorizedAccount: () => "Only the owner can do this.",
};

const ABIS = [nidhiHookAbi, nidhiDispatcherAbi, destinationReceiverAbi, roleAuthorityAbi, nidhiSwapRouterAbi] as unknown as Abi[];

export function explain(e: unknown): { text: string; raw: string } {
  const raw = e instanceof BaseError ? e.shortMessage : e instanceof Error ? e.message : String(e);
  if (e instanceof BaseError) {
    const rev = e.walk((x) => x instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
    let name = rev?.data?.errorName;
    let args = (rev?.data?.args ?? []) as readonly unknown[];
    // v4 wraps hook reverts: WrappedError(target, selector, reason, details) - unwrap the inner reason
    if (name === "WrappedError" && typeof args[2] === "string") {
      for (const abi of ABIS) {
        try { const d = decodeErrorResult({ abi, data: args[2] as `0x${string}` }); name = d.errorName; args = d.args ?? []; break; } catch { /* next */ }
      }
    }
    if (name && PLAIN[name]) return { text: PLAIN[name](args), raw: `${name} · ${raw}` };
    if (/User rejected|denied/i.test(raw)) return { text: "You cancelled the request in your wallet.", raw };
  }
  return { text: "The transaction was refused. The details are below.", raw };
}
