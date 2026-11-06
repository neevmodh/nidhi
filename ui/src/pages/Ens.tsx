import { useState } from "react";
import { Link } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { useAccount } from "wagmi";
import { decodeAbiParameters, encodeFunctionData, isAddress, namehash, stringToBytes, toHex, type Address, type Hex } from "viem";
import { addrUrl, chainById, client, ensOf, stackOf, type ChainInfo } from "../lib/chains";
import { short } from "../lib/format";
import { PageHead } from "../components/shell";
import { ChainName, Chip, Empty, ErrorNote, ExtLink, Hash, Icon, ProtocolLogo, Skel } from "../components/ui";

const SEPOLIA = 11155111;
const authAbi = [
  { type: "function", name: "APPROVER", stateMutability: "view", inputs: [], outputs: [{ type: "bytes32" }] },
  { type: "function", name: "AUDITOR", stateMutability: "view", inputs: [], outputs: [{ type: "bytes32" }] },
  { type: "function", name: "GUARDIAN", stateMutability: "view", inputs: [], outputs: [{ type: "bytes32" }] },
  { type: "function", name: "isAuthorized", stateMutability: "view", inputs: [{ type: "bytes32" }, { type: "address" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "resolveGrantee", stateMutability: "view", inputs: [{ type: "string" }, { type: "uint64" }], outputs: [{ type: "address" }] },
  { type: "function", name: "currentResolver", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;
const registryAbi = [{ type: "function", name: "getResolver", stateMutability: "view", inputs: [{ type: "string" }], outputs: [{ type: "address" }] }] as const;
const resolverAbi = [
  { type: "function", name: "hasRootRoles", stateMutability: "view", inputs: [{ type: "uint256" }, { type: "address" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "text", stateMutability: "view", inputs: [{ type: "bytes32" }, { type: "string" }], outputs: [{ type: "string" }] },
  { type: "function", name: "resolve", stateMutability: "view", inputs: [{ type: "bytes" }, { type: "bytes" }], outputs: [{ type: "bytes" }] },
] as const;

/** DNS wire format of a name, as ENSIP-10 resolve() takes it */
function dnsEncode(name: string): Hex {
  const parts = name.split(".").flatMap((l) => { const b = stringToBytes(l); return [b.length, ...b]; });
  return toHex(new Uint8Array([...parts, 0]));
}

/** a text record through ENSIP-10 resolve(name, text(node, key)): how ENSv2's PermissionedResolver answers */
async function readText(resolver: Address, name: string, key: string): Promise<string> {
  const data = encodeFunctionData({ abi: resolverAbi, functionName: "text", args: [namehash(name), key] });
  const out = (await client(SEPOLIA).readContract({ address: resolver, abi: resolverAbi, functionName: "resolve", args: [dnsEncode(name), data] })) as Hex;
  return out && out !== "0x" ? (decodeAbiParameters([{ type: "string" }], out)[0] as string) : "";
}
const ROLE_SET_ADDRESS = 1n;

function useEnsState(chain: ChainInfo) {
  const ens = ensOf(chain)!;
  const stack = stackOf(chain, "ens");
  return useQuery({
    queryKey: ["ens-state"],
    queryFn: async () => {
      const c = client(SEPOLIA);
      const read = (address: Address, abi: any, functionName: string, args: any[] = []) => c.readContract({ address, abi, functionName, args }) as Promise<any>;
      const [ap, au, gu, daoResolver] = await Promise.all([
        read(ens.authority, authAbi, "APPROVER"), read(ens.authority, authAbi, "AUDITOR"), read(ens.authority, authAbi, "GUARDIAN"),
        read(ens.authority, authAbi, "currentResolver"),
      ]);
      const [approverOk, auditorOk] = await Promise.all([
        read(ens.authority, authAbi, "isAuthorized", [ap, ens.approver]),
        read(ens.authority, authAbi, "isAuthorized", [au, ens.auditor]),
      ]);
      const labels = ens.grantees.split(",");
      const grantees = await Promise.all(labels.map(async (label) => {
        const resolver = (await read(ens.subregistry, registryAbi, "getResolver", [label])) as Address;
        const pays = await Promise.all(stack.lanes.map(async (to) => ({ to: chainById(to)!, addr: (await read(ens.authority, authAbi, "resolveGrantee", [label, chainById(to)!.selector])) as Address })));
        return { label, resolver, pays };
      }));
      const [bobOwnerCanSet, daoCanSetBob, attestation] = await Promise.all([
        read(ens.bobResolver, resolverAbi, "hasRootRoles", [ROLE_SET_ADDRESS, ens.granteeWallet]),
        read(ens.bobResolver, resolverAbi, "hasRootRoles", [ROLE_SET_ADDRESS, chain.deployment!.deployer]),
        readText(ens.sharedResolver, ens.auditorName, "nidhi.attestation").catch(() => ""),
      ]);
      return { roleIds: { approver: ap as Hex, auditor: au as Hex, guardian: gu as Hex }, daoResolver: daoResolver as Address, approverOk, auditorOk, grantees, bobOwnerCanSet, daoCanSetBob, attestation: attestation as string };
    },
    refetchInterval: 30_000,
  });
}

function RoleCheck({ chain }: { chain: ChainInfo }) {
  const ens = ensOf(chain)!;
  const { address } = useAccount();
  const [who, setWho] = useState("");
  const target = isAddress(who) ? (who as Address) : address;
  const q = useQuery({
    queryKey: ["ens-role", target],
    enabled: !!target,
    queryFn: async () => {
      const c = client(SEPOLIA);
      const ids = await Promise.all((["APPROVER", "AUDITOR", "GUARDIAN"] as const).map((n) => c.readContract({ address: ens.authority, abi: authAbi, functionName: n })));
      const ok = await Promise.all(ids.map((id) => c.readContract({ address: ens.authority, abi: authAbi, functionName: "isAuthorized", args: [id as Hex, target!] })));
      return { approver: ok[0], auditor: ok[1], guardian: ok[2] };
    },
  });
  return (
    <div className="card span-12">
      <span className="label">Check any address against {ens.name}</span>
      <div className="row row--wrap" style={{ marginTop: 16 }}>
        <input className="input mono" style={{ maxWidth: 480 }} value={who} onChange={(e) => setWho(e.target.value.trim())} placeholder={address ? `your wallet ${short(address)}` : "0x… address"} aria-label="Address to check" />
        {target && (q.data ? (
          <div className="row row--wrap">
            {(["approver", "auditor", "guardian"] as const).map((r) => q.data![r] ? <Chip key={r} tone="ok">{r}</Chip> : <Chip key={r} tone="idle">not {r}</Chip>)}
          </div>
        ) : <Skel w={240} />)}
      </div>
      <p className="small muted" style={{ marginTop: 12 }}>Each role is Enhanced Access Control permission to set one text record on the DAO's resolver. Revoking it in ENS stops that signer on the next swap.</p>
    </div>
  );
}

export default function Ens() {
  const chain = chainById(SEPOLIA)!;
  if (!ensOf(chain)) return <><PageHead title="ENS identity" /><Empty title="No ENSv2-gated stack is deployed." /></>;
  return <EnsBody chain={chain} />;
}

function EnsBody({ chain }: { chain: ChainInfo }) {
  const ens = ensOf(chain)!;
  const stack = stackOf(chain, "ens");
  const { data: s, error } = useEnsState(chain);
  const now = Math.floor(Date.now() / 1000);
  const carolLeft = ens.carolExpiry - now;

  return (
    <>
      <PageHead
        title={<span className="route" style={{ gap: 16 }}><ProtocolLogo name="ens" size="lg" />{ens.name}</span>}
        sub="On the Sepolia ENSv2-gated stack, the DAO's ENS name is the authority: it decides who may approve, audit and pause, and where every grantee is paid. Everything below is read live from ENSv2."
        action={<Link to="/app/new?stack=ens" className="btn btn--primary">Send an ENS-gated grant<Icon name="arrow-right" size="sm" /></Link>}
      />
      {error && <ErrorNote text="ENSv2 could not be read from Sepolia right now." raw={String(error)} />}

      <div className="section-title" style={{ marginTop: 0 }}><h2 className="h3">Roles, from Enhanced Access Control</h2></div>
      <div className="grid">
        <div className="card span-4">
          <span className="label">DAO resolver</span>
          <div style={{ marginTop: 12 }}>{s ? <Hash value={s.daoResolver} href={addrUrl(chain, s.daoResolver)} /> : <Skel />}</div>
          <p className="small muted" style={{ marginTop: 12 }}>Looked up from the registry on every check. If {ens.name} expires, every payout freezes.</p>
        </div>
        <div className="card span-4">
          <span className="label">Approver · nidhi.role.approver</span>
          <div className="row" style={{ marginTop: 12 }}><Hash value={ens.approver} href={addrUrl(chain, ens.approver)} />{s ? (s.approverOk ? <Chip tone="ok">holds it</Chip> : <Chip tone="bad">revoked</Chip>) : <Skel w={60} />}</div>
          <p className="small muted" style={{ marginTop: 12 }}>signs each mandate</p>
        </div>
        <div className="card span-4">
          <span className="label">Auditor · nidhi.role.auditor</span>
          <div className="row" style={{ marginTop: 12 }}><Hash value={ens.auditor} href={addrUrl(chain, ens.auditor)} />{s ? (s.auditorOk ? <Chip tone="ok">holds it</Chip> : <Chip tone="bad">revoked</Chip>) : <Skel w={60} />}</div>
          <p className="small muted" style={{ marginTop: 12 }}>the AI auditor agent's key</p>
        </div>
        <RoleCheck chain={chain} />
      </div>

      <div className="section-title"><h2 className="h3">Grantees are subnames</h2><span className="small muted">UserRegistry <span className="mono">{short(ens.subregistry)}</span></span></div>
      <div className="card" style={{ padding: "8px 24px 0" }}>
        <table className="table">
          <thead><tr><th>Name</th><th>Resolver</th>{stack.lanes.map((l) => <th key={l}>Paid on {chainById(l)?.short}</th>)}<th>Setup</th></tr></thead>
          <tbody>
            {(s?.grantees ?? ens.grantees.split(",").map((label) => ({ label, resolver: undefined as Address | undefined, pays: [] as { to: ChainInfo; addr: Address }[] }))).map((g) => (
              <tr key={g.label}>
                <td><span className="mono">{g.label}.{ens.name}</span></td>
                <td>{g.resolver ? <Hash value={g.resolver} href={addrUrl(chain, g.resolver)} /> : <Skel w={90} />}</td>
                {stack.lanes.map((l) => {
                  const p = g.pays.find((x) => x.to.id === l);
                  return <td key={l}>{!p ? <Skel w={90} /> : /^0x0+$/.test(p.addr) ? <Chip tone="bad">no address</Chip> : <span className="mono">{short(p.addr)}</span>}</td>;
                })}
                <td className="small">
                  {g.label === "alice" && "the DAO's shared resolver"}
                  {g.label === "bob" && (s ? (s.bobOwnerCanSet && !s.daoCanSetBob ? <Chip tone="ok">owns his resolver</Chip> : <Chip tone="warn">DAO still controls it</Chip>) : <Skel w={90} />)}
                  {g.label === "carol" && (carolLeft > 0 ? <Chip tone="flight">expires in {Math.floor(carolLeft / 3600)} h {Math.floor((carolLeft % 3600) / 60)} min</Chip> : <Chip tone="bad">expired · grants refused</Chip>)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="grid" style={{ marginTop: 24 }}>
        <div className="card span-4"><span className="label">alice</span><p className="small muted" style={{ marginTop: 8 }}>On the DAO's shared Permissioned Resolver, with one address per payout chain (ENSIP-11 coin types).</p></div>
        <div className="card span-4"><span className="label">bob</span><p className="small muted" style={{ marginTop: 8 }}>Has his own Permissioned Resolver. Only his wallet holds the address-setter role, so only he decides where he is paid.</p></div>
        <div className="card span-4"><span className="label">carol</span><p className="small muted" style={{ marginTop: 8 }}>Registered with an expiry that is her grant period. After it, ENS stops resolving her and the hook refuses to pay.</p></div>
      </div>

      <div className="section-title"><h2 className="h3">The AI auditor is an ENS agent</h2></div>
      <div className="grid">
        <div className="card span-7">
          <div className="card__label"><Icon name="signature" size="sm" /><span className="label">{ens.auditorName} · text record nidhi.attestation</span></div>
          <p className="mono small" style={{ overflowWrap: "anywhere" }}>{s ? (s.attestation || "No attestation published yet.") : <Skel w={320} />}</p>
          <p className="small muted" style={{ marginTop: 12 }}>The agent writes its verdict here after each audit: the grant and its evidence hash. Its key may set only this one record, through Enhanced Access Control.</p>
        </div>
        <div className="card span-5">
          <span className="label">ENS-gated stack</span>
          <dl className="kv small" style={{ marginTop: 12 }}>
            <dt>Authority</dt><dd><Hash value={ens.authority} href={addrUrl(chain, ens.authority)} /></dd>
            <dt>Hook</dt><dd><Hash value={stack.hook} href={addrUrl(chain, stack.hook)} /></dd>
            <dt>Dispatcher</dt><dd><Hash value={stack.dispatcher} href={addrUrl(chain, stack.dispatcher)} /></dd>
            <dt>Routes</dt><dd>{stack.lanes.map((l) => <div key={l}><ChainName chain={chainById(l)} /></div>)}</dd>
          </dl>
          <div style={{ marginTop: 16 }}><ExtLink href="https://docs.ens.domains/ensv2/enhanced-access-control">ENSv2 Enhanced Access Control</ExtLink></div>
        </div>
      </div>
    </>
  );
}
