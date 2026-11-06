import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter, Route, Routes } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider } from "wagmi";
import { AppProvider, wagmiConfig } from "./lib/app";
import { AppLayout } from "./components/shell";
import Landing from "./pages/Landing";
import Overview from "./pages/Overview";
import Grants from "./pages/Grants";
import GrantDetail from "./pages/GrantDetail";
import Network from "./pages/Network";
import Pool from "./pages/Pool";
import Roles from "./pages/Roles";
import Settings from "./pages/Settings";
import Ens from "./pages/Ens";
import Milestones from "./pages/Milestones";
import { Audit, NotFound, Queue } from "./pages/Misc";
import { Execute, NewGrant, Sign } from "./pages/Flow";
import "./styles/tokens.css";
import "./styles/base.css";
import "./styles/shell.css";
import "./styles/landing.css";

const qc = new QueryClient({ defaultOptions: { queries: { staleTime: 15_000, retry: 1, refetchOnWindowFocus: false } } });

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={qc}>
        <AppProvider>
          <BrowserRouter basename={import.meta.env.BASE_URL.replace(/\/$/, "")}>
            <Routes>
              <Route path="/" element={<AppLayout />}><Route index element={<Landing />} /></Route>
              <Route path="/app" element={<AppLayout />}>
                <Route index element={<Overview />} />
                <Route path="grants" element={<Grants />} />
                <Route path="grants/:chain/:id" element={<GrantDetail />} />
                <Route path="new" element={<NewGrant />} />
                <Route path="audit/:label" element={<Audit />} />
                <Route path="sign" element={<Sign />} />
                <Route path="execute" element={<Execute />} />
                <Route path="network" element={<Network />} />
                <Route path="pool" element={<Pool />} />
                <Route path="queue" element={<Queue />} />
                <Route path="roles" element={<Roles />} />
                <Route path="ens" element={<Ens />} />
                <Route path="milestones" element={<Milestones />} />
                <Route path="settings" element={<Settings />} />
                <Route path="*" element={<NotFound />} />
              </Route>
              <Route path="*" element={<AppLayout />}><Route path="*" element={<NotFound />} /></Route>
            </Routes>
          </BrowserRouter>
        </AppProvider>
      </QueryClientProvider>
    </WagmiProvider>
  </StrictMode>,
);
