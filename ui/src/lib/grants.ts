import { parseAbiItem, type Address, type Hex, type Log } from "viem";
import { useQuery } from "@tanstack/react-query";
import { client, chainById, chainBySelector, deployedChains, type ChainInfo } from "./chains";
import { destinationReceiverAbi, nidhiDispatcherAbi, nidhiHookAbi, roleAuthorityAbi } from "../data/abi";

// Ledger statuses as stored on-chain (NidhiDispatcher.Status) and receiver outcomes (AckLib).
export const STATUS = ["None", "In flight", "Held", "Settled"] as const;
export type Status = 0 | 1 | 2 | 3;
export const OUTCOME: Record<number, string> = { 0: "Not received", 1: "Paid", 2: "Held", 3: "Recovered" };

export interface Grant {
  id: Hex;
  src: ChainInfo;
  dest?: ChainInfo;
  status: Status;
  outcome: number;
  amount: bigint;
  token: Address;
  recipient: Address;
  messageId: Hex;
  dispatchedAt: number;
  fee: bigint;
  dispatchTx: Hex;
  label?: string;
}

export interface Payout {
  outcome: number;
  ackPending: boolean;
  amount: bigint;
  receivedTx?: Hex;
  paidTx?: Hex;
  ackTx?: Hex;
  ackMessageId?: Hex;
}

const EV = {
  dispatched: parseAbiItem("event GrantDispatched(bytes32 indexed grantId, bytes32 indexed messageId, address token, uint256 amount, address recipient, uint256 fee)"),
  acknowledged: parseAbiItem("event GrantAcknowledged(bytes32 indexed grantId, bytes32 indexed messageId, uint8 outcome, uint8 status)"),
  authorized: parseAbiItem("event GrantAuthorized(bytes32 indexed grantId, address indexed approver, address indexed auditor, address executor)"),
  received: parseAbiItem("event GrantReceived(bytes32 indexed grantId, bytes32 indexed messageId, address recipient, uint256 amount)"),
  paid: parseAbiItem("event PayoutSucceeded(bytes32 indexed grantId, address indexed recipient, uint256 amount)"),
  held: parseAbiItem("event PayoutHeld(bytes32 indexed grantId, address indexed recipient, uint256 amount, bytes reason)"),
  ackSent: parseAbiItem("event AckSent(bytes32 indexed grantId, bytes32 indexed ackMessageId, uint8 outcome)"),
  granteeSet: parseAbiItem("event GranteeSet(string label, uint64 indexed destSelector, address indexed account, address indexed by)"),
};

/** getLogs in windows, so public RPC range limits never blank a screen. */
async function logs<T extends (typeof EV)[keyof typeof EV]>(chainId: number, address: Address, event: T, args?: any): Promise<Log[]> {
  const c = client(chainId);
  const from = BigInt(chainById(chainId)?.deployment?.fromBlock ?? 0);
  const latest = await c.getBlockNumber();
  const step = chainId === 421614 ? 40_000n : 9_000n;
  const out: Log[] = [];
  for (let start = from; start <= latest; start += step + 1n) {
    const end = start + step > latest ? latest : start + step;
    out.push(...((await c.getLogs({ address, event: event as any, args, fromBlock: start, toBlock: end })) as Log[]));
  }
  return out;
}

/** label for a recipient, from RoleAuthority.GranteeSet on the source chain */
async function labelsFor(src: ChainInfo): Promise<Map<string, string>> {
  const m = new Map<string, string>();
  if (!src.deployment) return m;
  for (const l of (await logs(src.id, src.deployment.authority, EV.granteeSet)) as any[]) {
    m.set(`${l.args.destSelector}:${String(l.args.account).toLowerCase()}`, l.args.label);
  }
  return m;
}

async function grantsOn(src: ChainInfo): Promise<Grant[]> {
  const d = src.deployment!;
  const [dispatched, labels] = await Promise.all([logs(src.id, d.dispatcher, EV.dispatched), labelsFor(src)]);
  const c = client(src.id);
  const rows = await Promise.all(
    (dispatched as any[]).map(async (l) => {
      const g = (await c.readContract({ address: d.dispatcher, abi: nidhiDispatcherAbi, functionName: "getGrant", args: [l.args.grantId] })) as any;
      const block = await c.getBlock({ blockNumber: l.blockNumber });
      const dest = chainBySelector(BigInt(g.destSelector));
      return {
        id: l.args.grantId,
        src,
        dest,
        status: Number(g.status) as Status,
        outcome: Number(g.outcome),
        amount: BigInt(g.amount),
        token: g.token,
        recipient: g.recipient,
        messageId: g.messageId,
        dispatchedAt: Number(block.timestamp),
        fee: l.args.fee,
        dispatchTx: l.transactionHash,
        label: labels.get(`${g.destSelector}:${String(g.recipient).toLowerCase()}`),
      } satisfies Grant;
    }),
  );
  return rows;
}

export function useGrants(chainId?: number) {
  return useQuery({
    queryKey: ["grants", chainId ?? "all"],
    queryFn: async () => {
      const chains = deployedChains().filter((c) => chainId === undefined || c.id === chainId);
      const settled = await Promise.allSettled(chains.map(grantsOn));
      const ok = settled.flatMap((s) => (s.status === "fulfilled" ? s.value : []));
      const failed = chains.filter((_, i) => settled[i].status === "rejected").map((c) => c.short);
      return { grants: ok.sort((a, b) => b.dispatchedAt - a.dispatchedAt), failed };
    },
    refetchInterval: 30_000,
  });
}

export function useGrant(chainId: number, id: Hex) {
  return useQuery({
    queryKey: ["grant", chainId, id],
    queryFn: async () => {
      const src = chainById(chainId);
      if (!src?.deployment) throw new Error("This chain has no deployment.");
      const all = await grantsOn(src);
      const g = all.find((x) => x.id.toLowerCase() === id.toLowerCase());
      if (!g) throw new Error("No grant with this id on this chain.");
      const d = src.deployment;
      const [auth, ack] = await Promise.all([
        logs(src.id, d.hook, EV.authorized, { grantId: g.id }),
        logs(src.id, d.dispatcher, EV.acknowledged, { grantId: g.id }),
      ]);
      let payout: Payout | undefined;
      if (g.dest?.deployment) {
        const rx = g.dest.deployment.receiver;
        const p = (await client(g.dest.id).readContract({ address: rx, abi: destinationReceiverAbi, functionName: "getPayout", args: [g.id] })) as any;
        const [rec, paid, held, sent] = await Promise.all([
          logs(g.dest.id, rx, EV.received, { grantId: g.id }),
          logs(g.dest.id, rx, EV.paid, { grantId: g.id }),
          logs(g.dest.id, rx, EV.held, { grantId: g.id }),
          logs(g.dest.id, rx, EV.ackSent, { grantId: g.id }),
        ]);
        payout = {
          outcome: Number(p.outcome),
          ackPending: Boolean(p.ackPending),
          amount: BigInt(p.amount),
          receivedTx: rec[0]?.transactionHash ?? undefined,
          paidTx: (paid[0] ?? held[0])?.transactionHash ?? undefined,
          ackTx: sent[0]?.transactionHash ?? undefined,
          ackMessageId: (sent[0] as any)?.args?.ackMessageId,
        };
      }
      const a = auth[0] as any;
      return {
        grant: g,
        approver: a?.args?.approver as Address | undefined,
        auditor: a?.args?.auditor as Address | undefined,
        executor: a?.args?.executor as Address | undefined,
        swapTx: a?.transactionHash as Hex | undefined,
        ackTx: ack[0]?.transactionHash as Hex | undefined,
        payout,
      };
    },
    refetchInterval: (q) => (q.state.data?.grant.status === 3 ? false : 20_000),
  });
}

/** live hook + dispatcher state for one chain */
export function useChainState(chainId: number) {
  return useQuery({
    queryKey: ["state", chainId],
    queryFn: async () => {
      const ch = chainById(chainId)!;
      const d = ch.deployment!;
      const c = client(chainId);
      const [remaining, cap, paused, feeReserve, rxReserve, queue, rxOwner, dispOwner, dispPending] = await Promise.all([
        c.readContract({ address: d.hook, abi: nidhiHookAbi, functionName: "remainingToday" }) as Promise<bigint>,
        c.readContract({ address: d.hook, abi: nidhiHookAbi, functionName: "maxAmountInPerDay" }) as Promise<bigint>,
        c.readContract({ address: d.hook, abi: nidhiHookAbi, functionName: "paused" }) as Promise<boolean>,
        c.getBalance({ address: d.dispatcher }),
        c.getBalance({ address: d.receiver }),
        c.readContract({ address: d.receiver, abi: destinationReceiverAbi, functionName: "queueLength" }) as Promise<bigint>,
        c.readContract({ address: d.receiver, abi: destinationReceiverAbi, functionName: "owner" }) as Promise<Address>,
        c.readContract({ address: d.dispatcher, abi: nidhiDispatcherAbi, functionName: "owner" }) as Promise<Address>,
        c.readContract({ address: d.dispatcher, abi: nidhiDispatcherAbi, functionName: "pendingOwner" }) as Promise<Address>,
      ]);
      const routes = await Promise.all(
        ch.lanes.map(async (to) => {
          const dest = chainById(to)!;
          const rx = (await c.readContract({ address: d.dispatcher, abi: nidhiDispatcherAbi, functionName: "destReceivers", args: [dest.selector] })) as Address;
          return { to: dest, wired: rx !== "0x0000000000000000000000000000000000000000" };
        }),
      );
      let cursed: boolean | null = null;
      try {
        const arm = (await c.readContract({ address: ch.ccipRouter, abi: [{ type: "function", name: "getArmProxy", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] }], functionName: "getArmProxy" })) as Address;
        cursed = (await c.readContract({ address: arm, abi: [{ type: "function", name: "isCursed", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] }], functionName: "isCursed" })) as boolean;
      } catch { cursed = null; }
      return { remaining, cap, paused, feeReserve, rxReserve, queue, rxOwner, dispOwner, dispPending, routes, cursed };
    },
    refetchInterval: 30_000,
  });
}

/** grantee names registered on a chain's RoleAuthority (latest wins) and role holders */
export function useRoles(chainId: number) {
  return useQuery({
    queryKey: ["roles", chainId],
    queryFn: async () => {
      const ch = chainById(chainId)!;
      const d = ch.deployment!;
      const c = client(chainId);
      const set = (await logs(chainId, d.authority, EV.granteeSet)) as any[];
      const latest = new Map<string, any>();
      for (const l of set) latest.set(`${l.args.label}:${l.args.destSelector}`, l);
      const grantees = await Promise.all(
        [...latest.values()].map(async (l) => {
          const blk = await c.getBlock({ blockNumber: l.blockNumber });
          return { label: l.args.label as string, dest: chainBySelector(BigInt(l.args.destSelector)), account: l.args.account as Address, by: l.args.by as Address, at: Number(blk.timestamp) };
        }),
      );
      const roleIds = await Promise.all(
        (["APPROVER", "AUDITOR", "GUARDIAN", "GRANTEE_ADMIN", "DEFAULT_ADMIN_ROLE"] as const).map((n) =>
          c.readContract({ address: d.authority, abi: roleAuthorityAbi, functionName: n }) as Promise<Hex>,
        ),
      );
      const granted = (await logs(chainId, d.authority, parseAbiItem("event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)") as any)) as any[];
      const revoked = (await logs(chainId, d.authority, parseAbiItem("event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender)") as any)) as any[];
      const holders = (role: Hex) => {
        const s = new Set<string>();
        for (const e of [...granted.map((g) => ({ ...g, on: true })), ...revoked.map((r) => ({ ...r, on: false }))].sort((a, b) => Number(a.blockNumber - b.blockNumber) || a.logIndex - b.logIndex)) {
          if (e.args.role !== role) continue;
          if (e.on) s.add(e.args.account); else s.delete(e.args.account);
        }
        return [...s] as Address[];
      };
      const [approver, auditor, guardian, granteeAdmin, admin] = roleIds;
      return {
        grantees: grantees.sort((a, b) => b.at - a.at),
        roles: { approver: holders(approver), auditor: holders(auditor), guardian: holders(guardian), granteeAdmin: holders(granteeAdmin), admin: holders(admin) },
      };
    },
    refetchInterval: 60_000,
  });
}
