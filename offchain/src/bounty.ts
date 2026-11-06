// On-chain milestones (NidhiBountyBoard): reading them, checking their spec, and giving winners an ENS identity.
import fs from "node:fs";
import path from "node:path";
import { createWalletClient, encodeFunctionData, http, keccak256, parseAbi, parseEventLogs, toHex, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { hashJson } from "./lib.ts";
import { RPCS, publicClient, repoRoot } from "./stack.ts";

const read = (p: string) => JSON.parse(fs.readFileSync(path.join(repoRoot, p), "utf8"));
export const boardDeployment = () => {
  const f = path.join(repoRoot, "deployments", "bounty-board.json");
  return fs.existsSync(f) ? read("deployments/bounty-board.json") : null;
};
// committed copy of the Foundry ABI, so the agent runs in CI without a Solidity build
export const boardAbi = JSON.parse(fs.readFileSync(path.join(repoRoot, "offchain", "src", "abi", "NidhiBountyBoard.json"), "utf8"));

export interface BoardBounty {
  id: bigint;
  poster: Address;
  grantId: Hex;
  specHash: Hex;
  spec: { title: string; repo: string; body: string; rules: string; grantee: string };
  bounty: any; // the on-chain Bounty struct
  cancelled: boolean;
}

/**
 * The spec hash a poster commits to: the same canonical JSON the app hashes when posting. The agent recomputes it
 * from the emitted spec and refuses any milestone whose text does not match what was committed on-chain.
 */
export function bountySpecHash(spec: BoardBounty["spec"], destChainSelector: bigint | string, amountIn: bigint | string): Hex {
  let rules: unknown = {};
  try { rules = JSON.parse(spec.rules || "{}"); } catch { rules = spec.rules; }
  return hashJson({
    kind: "nidhi.bounty.v1",
    title: spec.title, repo: spec.repo, body: spec.body, rules, grantee: spec.grantee,
    destChainSelector: String(destChainSelector), amountIn: String(amountIn),
  });
}

export async function readBounties(): Promise<BoardBounty[]> {
  const d = boardDeployment();
  if (!d) return [];
  const c = publicClient(11155111);
  const latest = await c.getBlockNumber();
  const logs = [];
  for (let s = BigInt(d.deployBlock); s <= latest; s += 9001n) {
    const e = s + 9000n > latest ? latest : s + 9000n;
    logs.push(...(await c.getLogs({ address: d.board, fromBlock: s, toBlock: e })));
  }
  const parsed = parseEventLogs({ abi: boardAbi, logs, strict: false }) as any[];
  const cancelled = new Set(parsed.filter((l) => l.eventName === "BountyCancelled").map((l) => String(l.args.id)));
  return parsed.filter((l) => l.eventName === "BountyPosted").map((l) => ({
    id: l.args.id, poster: l.args.poster, grantId: l.args.grantId, specHash: l.args.specHash,
    spec: l.args.spec, bounty: l.args.bounty, cancelled: cancelled.has(String(l.args.id)),
  }));
}

// ------------------------------------------------------------------ ENS identities for contributors

const ENS_VERIFIABLE_FACTORY = "0xDa70306C98E97eCe36F997a21368e53298572991" as Address;
const ENS_RESOLVER_IMPL = "0x115eb53F0c60696633855F90b138178Fb40b2b2C" as Address;
const ROLE_SET_ADDRESS = 1n, ROLE_SET_TEXT = 1n << 4n, ADMIN = 128n;

const factoryAbi = parseAbi(["function deployProxy(address implementation, uint256 salt, bytes data) returns (address)"]);
const resolverAbi = parseAbi([
  "function initialize((address account, uint256 roleBitmap)[] grants, bytes[] calls)",
  "function setAddress(bytes name, uint256 coinType, bytes addressBytes)",
  "function setText(bytes name, string key, string value)",
  "function revokeRootRoles(uint256 roleBitmap, address account) returns (bool)",
  "function resolve(bytes name, bytes data) view returns (bytes)",
  "function text(bytes32 node, string key) view returns (string)",
]);
const registryAbi = parseAbi([
  "function register(string label, address owner, address registry, address resolver, uint256 roleBitmap, uint64 expiry) returns (uint256)",
  "function getResolver(string label) view returns (address)",
]);

export const dnsName = (sub: string, label: string) => {
  const enc = new TextEncoder();
  return toHex(new Uint8Array([sub.length, ...enc.encode(sub), label.length, ...enc.encode(label), 3, ...enc.encode("eth"), 0]));
};
export const coinTypeOf = (chainId: number) => BigInt(0x80000000 | chainId);
export const validLabel = (s: string) => /^[a-z0-9-]{1,63}$/.test(s);

/**
 * Give a contributor `<login>.nidhi-dao.eth`: their own Permissioned Resolver (they hold the setter roles), their wallet
 * for the payout chain, and com.github = <login>. The DAO key sets the first records, then renounces its roles, so the
 * contributor owns the name's data. Idempotent: an existing name is left untouched.
 */
export async function ensureContributorName(login: string, wallet: Address, payToChainId: number, log: (m: string) => void): Promise<"existing" | Hex> {
  const subs = read("deployments/sepolia-subnames.json");
  const dao = read("deployments/sepolia-ens.json").label as string;
  const pub = publicClient(11155111);
  if ((await pub.readContract({ address: subs.subregistry, abi: registryAbi, functionName: "getResolver", args: [login] })) !== "0x0000000000000000000000000000000000000000") return "existing";

  const key = process.env.PRIVATE_KEY as Hex;
  const account = privateKeyToAccount(key);
  const w = createWalletClient({ chain: sepolia, transport: http(RPCS[11155111][0]), account });
  const send = async (what: string, p: Promise<Hex>) => { const h = await p; await pub.waitForTransactionReceipt({ hash: h }); log(`  ens ${what}: ${h}`); return h; };
  const init = encodeFunctionData({ abi: resolverAbi, functionName: "initialize", args: [[
    { account: account.address, roleBitmap: ROLE_SET_ADDRESS | (ROLE_SET_ADDRESS << ADMIN) | ROLE_SET_TEXT | (ROLE_SET_TEXT << ADMIN) },
    { account: wallet, roleBitmap: ROLE_SET_ADDRESS | (ROLE_SET_ADDRESS << ADMIN) | ROLE_SET_TEXT | (ROLE_SET_TEXT << ADMIN) },
  ], []] });
  const salt = BigInt(keccak256(toHex(`nidhi.contributor:${login}:${wallet}`)));
  const { result: resolver, request } = await pub.simulateContract({ account, address: ENS_VERIFIABLE_FACTORY, abi: factoryAbi, functionName: "deployProxy", args: [ENS_RESOLVER_IMPL, salt, init] });
  await send("own resolver", w.writeContract(request));
  const name = dnsName(login, dao);
  await send("register", w.writeContract({ address: subs.subregistry, abi: registryAbi, functionName: "register", args: [login, wallet, "0x0000000000000000000000000000000000000000", resolver as Address, 0n, BigInt(Math.floor(Date.now() / 1000) + 365 * 86400)] }));
  await send("address", w.writeContract({ address: resolver as Address, abi: resolverAbi, functionName: "setAddress", args: [name, coinTypeOf(payToChainId), wallet] }));
  await send("com.github", w.writeContract({ address: resolver as Address, abi: resolverAbi, functionName: "setText", args: [name, "com.github", login] }));
  return send("hand over", w.writeContract({ address: resolver as Address, abi: resolverAbi, functionName: "revokeRootRoles", args: [ROLE_SET_ADDRESS | (ROLE_SET_ADDRESS << ADMIN) | ROLE_SET_TEXT | (ROLE_SET_TEXT << ADMIN), account.address] }));
}

/** the com.github record of `<login>.nidhi-dao.eth`, via ENSIP-10 resolve (how ENSv2's resolver answers) */
export async function githubOf(login: string): Promise<string> {
  const subs = read("deployments/sepolia-subnames.json");
  const dao = read("deployments/sepolia-ens.json").label as string;
  const pub = publicClient(11155111);
  const resolver = (await pub.readContract({ address: subs.subregistry, abi: registryAbi, functionName: "getResolver", args: [login] })) as Address;
  if (/^0x0+$/.test(resolver)) return "";
  const { namehash, decodeAbiParameters } = await import("viem");
  const full = `${login}.${dao}.eth`;
  const data = encodeFunctionData({ abi: resolverAbi, functionName: "text", args: [namehash(full), "com.github"] });
  try {
    const out = (await pub.readContract({ address: resolver, abi: resolverAbi, functionName: "resolve", args: [dnsName(login, dao), data] })) as Hex;
    return out && out !== "0x" ? (decodeAbiParameters([{ type: "string" }], out)[0] as string) : "";
  } catch { return ""; }
}
