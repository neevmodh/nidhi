import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import { createConfig, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { arbitrumSepolia, baseSepolia, sepolia, unichainSepolia } from "viem/chains";
import { CHAINS, rpcUrls, type ChainId } from "./chains";

export const wagmiConfig = createConfig({
  chains: [sepolia, baseSepolia, arbitrumSepolia, unichainSepolia],
  connectors: [injected()],
  transports: {
    [sepolia.id]: http(rpcUrls(11155111)[0]),
    [baseSepolia.id]: http(rpcUrls(84532)[0]),
    [arbitrumSepolia.id]: http(rpcUrls(421614)[0]),
    [unichainSepolia.id]: http(rpcUrls(1301)[0]),
  },
});

type Grade = "evening" | "day";
interface AppState { chainId: ChainId; setChainId: (id: ChainId) => void; grade: Grade; setGrade: (g: Grade) => void; }
const Ctx = createContext<AppState | null>(null);

// per-viewer conveniences only; the page works without storage
const load = (k: string) => { try { return localStorage.getItem(k); } catch { return null; } };
const save = (k: string, v: string) => { try { localStorage.setItem(k, v); } catch { /* private mode */ } };

export function AppProvider({ children }: { children: ReactNode }) {
  const first = (CHAINS.find((c) => c.id === 84532) ?? CHAINS[0]).id;
  const [chainId, setChainIdRaw] = useState<ChainId>(() => (Number(load("nidhi.chain")) as ChainId) || first);
  const [grade, setGradeRaw] = useState<Grade>(() => (new URLSearchParams(location.search).get("grade") as Grade) || (load("nidhi.grade") as Grade) || "evening");
  useEffect(() => { document.documentElement.dataset.grade = grade; }, [grade]);
  const setChainId = (id: ChainId) => { setChainIdRaw(id); save("nidhi.chain", String(id)); };
  const setGrade = (g: Grade) => { setGradeRaw(g); save("nidhi.grade", g); };
  return <Ctx.Provider value={{ chainId, setChainId, grade, setGrade }}>{children}</Ctx.Provider>;
}
export const useApp = () => useContext(Ctx)!;
