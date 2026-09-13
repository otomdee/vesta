import { createContext, useContext, useState, useCallback, useRef } from "react";
import { ethers } from "ethers";
import {
  CHAIN_ID, CHAIN_HEX, EXPLORER,
  ABI_STRATEGY, ABI_VAULT, ABI_ADAPTER, ABI_CCA, ABI_LIQ, ABI_TOKEN,
  MAX_BID_SCAN, Q96, DEFAULT_RPC,
} from "../lib/constants.js";
import { fmtEth, fmtPrice, fmtToks, short, bidPriceToQ96 } from "../lib/format.js";

const VestaCtx = createContext(null);
export const useVesta = () => useContext(VestaCtx);

const EMPTY_LAUNCH = {
  lifecycle: null, auctionComplete: false, clearingPrice: 0n,
  lockDuration: 0n, penaltyBps: 0, escrowedEth: 0n,
  committedTokens: 0n, positionShares: 0n, rewardPot: 0n, participants: [],
};
const EMPTY_AUCTION = {
  endBlock: 0n, claimBlock: 0n, graduated: false, clearingPrice: 0n,
  nextBidId: 0n, floor: 0n, spacing: 0n, currency: "",
};

export function VestaProvider({ children }) {
  const [rpcUrl, setRpcUrl] = useState(DEFAULT_RPC);
  const [connected, setConnected] = useState(false);
  const [netStatus, setNetStatus] = useState({ ok: false, text: "not connected" });
  const [addrs, setAddrs] = useState({});
  const [symbol, setSymbol] = useState("TKN");
  const [wallets, setWallets] = useState({ team: null, user: null });
  const [launchData, setLaunchData] = useState(EMPTY_LAUNCH);
  const [auctionData, setAuctionData] = useState(EMPTY_AUCTION);
  const [participantRows, setParticipantRows] = useState([]);
  const [userEnrollment, setUserEnrollment] = useState(null);
  const [userPosition, setUserPosition] = useState(null);
  const [myBids, setMyBids] = useState([]);
  const [activityLog, setActivityLog] = useState([]);
  const [currentBlock, setCurrentBlock] = useState(0);

  const provRef = useRef(null);
  const cRef = useRef({});
  const addrsRef = useRef({});

  const addLog = useCallback((msg, status = "info") => {
    setActivityLog((prev) => [
      { id: Date.now() + Math.random(), time: new Date().toLocaleTimeString(), msg, status },
      ...prev,
    ]);
  }, []);

  /* ─── sendTx ─── */
  const sendTx = useCallback(async (label, fn) => {
    addLog(`${label}…`, "pending");
    try {
      const tx = await fn();
      const rc = await tx.wait();
      if (rc.status === 0) throw new Error("tx reverted");
      addLog(`${label} confirmed — ${rc.hash}`, "ok");
      return rc;
    } catch (e) {
      const msg = (e && e.shortMessage) || (e && e.reason) || (e && e.message) || String(e);
      addLog(`${label} failed — ${String(msg).slice(0, 200)}`, "error");
      return null;
    }
  }, [addLog]);

  /* ─── connect ─── */
  const connect = useCallback(async (strategyAddr, auctionAddr, rpc) => {
    const url = rpc || rpcUrl;
    try {
      const provider = new ethers.JsonRpcProvider(url);
      const net = await provider.getNetwork();
      const block = await provider.getBlockNumber();
      if (net.chainId !== CHAIN_ID) {
        setNetStatus({ ok: false, text: `wrong chain ${net.chainId} — need Sepolia` });
        addLog(`RPC is chain ${net.chainId}, not Sepolia`, "error");
        return false;
      }
      setCurrentBlock(block);
      setNetStatus({ ok: true, text: `Sepolia · block ${block}` });

      if (!ethers.isAddress(strategyAddr) || strategyAddr === ethers.ZeroAddress)
        throw new Error("strategy address missing");
      if (!ethers.isAddress(auctionAddr) || auctionAddr === ethers.ZeroAddress)
        throw new Error("auction address missing");

      const strategy = new ethers.Contract(strategyAddr, ABI_STRATEGY, provider);
      const vault   = await strategy.vault();
      const token   = await strategy.launchToken();
      const auctionAdapter    = await strategy.auctionAdapter();
      const liquidityAdapter  = await strategy.liquidityAdapter();
      const owner   = await strategy.owner();

      if (vault === ethers.ZeroAddress) throw new Error("no vault at strategy");

      let positionManager = null;
      try {
        const liq = new ethers.Contract(liquidityAdapter, ABI_LIQ, provider);
        positionManager = await liq.POSITION_MANAGER();
      } catch { /* optional */ }

      let sym = "TKN";
      try {
        const tk = new ethers.Contract(token, ABI_TOKEN, provider);
        sym = await tk.symbol();
      } catch { /* optional */ }

      const newAddrs = { strategy: strategyAddr, auction: auctionAddr, vault, token, auctionAdapter, liquidityAdapter, owner, positionManager };

      provRef.current = provider;
      addrsRef.current = newAddrs;
      cRef.current = {
        strategy: new ethers.Contract(strategyAddr, ABI_STRATEGY, provider),
        vault:    new ethers.Contract(vault, ABI_VAULT, provider),
        adapter:  new ethers.Contract(auctionAdapter, ABI_ADAPTER, provider),
        cca:      new ethers.Contract(auctionAddr, ABI_CCA, provider),
        token:    new ethers.Contract(token, ABI_TOKEN, provider),
      };

      setAddrs(newAddrs);
      setSymbol(sym);
      setConnected(true);
      addLog(`Connected to Sepolia — strategy ${short(strategyAddr)}`, "ok");

      // kick off initial data fetch
      await doRefreshAuction(newAddrs);
      await doRefreshLaunch(newAddrs);
      return true;
    } catch (e) {
      setNetStatus({ ok: false, text: "connection failed" });
      addLog(`Connect failed — ${e.shortMessage || e.message || e}`, "error");
      return false;
    }
  }, [rpcUrl, addLog]);

  const loadDeploymentFile = useCallback(async () => {
    try {
      const r = await fetch("./deployment.sepolia.json", { cache: "no-store" });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const j = await r.json();
      if (!j.strategy) throw new Error("missing strategy key");
      addLog(`deployment.sepolia.json loaded`, "ok");
      return { strategy: j.strategy, auction: j.auctionAddress || "" };
    } catch (e) {
      addLog(`Could not load deployment file — ${e.message}`, "error");
      return null;
    }
  }, [addLog]);

  /* ─── wallet ─── */
  const connectWallet = useCallback(async (role) => {
    try {
      if (!window.ethereum) throw new Error("no wallet found (install MetaMask)");
      await window.ethereum.request({ method: "eth_requestAccounts" });
      let bp = new ethers.BrowserProvider(window.ethereum);
      const net = await bp.getNetwork();
      if (net.chainId !== CHAIN_ID) {
        try {
          await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: CHAIN_HEX }] });
        } catch (e) {
          if (e && e.code === 4902) {
            await window.ethereum.request({
              method: "wallet_addEthereumChain",
              params: [{ chainId: CHAIN_HEX, chainName: "Sepolia", nativeCurrency: { name: "Sepolia ETH", symbol: "ETH", decimals: 18 }, rpcUrls: [DEFAULT_RPC], blockExplorerUrls: [EXPLORER] }],
            });
          } else throw e;
        }
        bp = new ethers.BrowserProvider(window.ethereum);
      }
      const signer  = await bp.getSigner();
      const address = await signer.getAddress();
      setWallets((prev) => ({ ...prev, [role]: { signer, address } }));
      addLog(`${role} wallet connected — ${short(address)}`, "ok");
      return address;
    } catch (e) {
      addLog(`Wallet connect failed — ${e.shortMessage || e.message}`, "error");
      return null;
    }
  }, [addLog]);

  /* ─── reads ─── */
  const doRefreshAuction = async (a) => {
    const c = cRef.current.cca;
    if (!c) return;
    try {
      const [end, claim, grad, price, next, floor, spacing, cur] = await Promise.all([
        c.endBlock(), c.claimBlock(), c.isGraduated(), c.clearingPrice(),
        c.nextBidId(), c.floorPrice(), c.tickSpacing(), c.currency(),
      ]);
      const blk = await provRef.current.getBlockNumber();
      setCurrentBlock(blk);
      setAuctionData({ endBlock: end, claimBlock: claim, graduated: grad, clearingPrice: price, nextBidId: next, floor, spacing, currency: cur === ethers.ZeroAddress ? "ETH" : short(cur) });
    } catch { /* ignore */ }
  };

  const doRefreshLaunch = async (a) => {
    const addr = a || addrsRef.current;
    const v = cRef.current.vault;
    const adapter = cRef.current.adapter;
    if (!v || !adapter) return;
    try {
      const [lc, lock, bps, esc, com, shares, pot, complete, price] = await Promise.all([
        v.lifecycle(), v.lockDuration(), v.earlyExitPenaltyBps(), v.totalEscrowedEth(),
        v.totalCommittedTokens(), v.totalPositionShares(), v.rewardPot(),
        adapter.isAuctionComplete(addr.auction), adapter.clearingPrice(addr.auction),
      ]);
      const list = await v.participants();
      const rows = await Promise.all(list.map(async (p) => {
        const [cm, alloc] = await Promise.all([v.commitmentOf(p), adapter.claimableAllocation(addr.auction, p)]);
        return { address: p, active: cm.active, commitmentBps: Number(cm.commitmentBps), escrowedEth: cm.escrowedEth, allocation: alloc, ready: alloc > 0n };
      }));
      setLaunchData({ lifecycle: Number(lc), auctionComplete: complete, clearingPrice: price, lockDuration: lock, penaltyBps: Number(bps), escrowedEth: esc, committedTokens: com, positionShares: shares, rewardPot: pot, participants: list });
      setParticipantRows(rows);
    } catch { /* ignore */ }
  };

  const refreshAll = useCallback(async () => {
    await Promise.all([doRefreshAuction(), doRefreshLaunch()]);
  }, []);

  const refreshUser = useCallback(async (userAddr) => {
    const addr = addrsRef.current;
    const v = cRef.current.vault;
    const adapter = cRef.current.adapter;
    const tok = cRef.current.token;
    if (!v || !adapter || !ethers.isAddress(userAddr)) return;
    try {
      const [cm, alloc, pos, pend, tbal, ebal] = await Promise.all([
        v.commitmentOf(userAddr), adapter.claimableAllocation(addr.auction, userAddr),
        v.positionOf(userAddr), v.pendingRewards(userAddr),
        tok.balanceOf(userAddr), provRef.current.getBalance(userAddr),
      ]);
      setUserEnrollment({ active: cm.active, commitmentBps: Number(cm.commitmentBps), escrowedEth: cm.escrowedEth, allocation: alloc });
      setUserPosition({ shares: pos.shares, tokenId: pos.tokenId, tokenAmount: pos.tokenAmount, ethAmount: pos.ethAmount, finalizedAt: pos.finalizedAt, unlockTime: pos.unlockTime, exited: pos.exited, pendingRewards: pend, tokenBalance: tbal, ethBalance: ebal });
    } catch { /* ignore */ }
  }, []);

  const refreshMyBids = useCallback(async (userAddr) => {
    const c = cRef.current.cca;
    if (!c || !ethers.isAddress(userAddr)) return;
    try {
      const next = await c.nextBidId();
      const n = Number(next);
      const scan = Math.min(n, MAX_BID_SCAN);
      const bids = [];
      for (let id = 0; id < scan; id++) {
        const b = await c.bids(id);
        if (b.owner.toLowerCase() !== userAddr.toLowerCase()) continue;
        bids.push({ id, maxPrice: b.maxPrice, amountQ96: b.amountQ96, tokensFilled: b.tokensFilled, exited: b.exitedBlock !== 0n });
      }
      setMyBids(bids);
    } catch { /* ignore */ }
  }, []);

  /* ─── writes ─── */
  const teamSgn = () => { if (!wallets.team) throw new Error("connect team wallet first"); return wallets.team.signer; };
  const userSgn = () => { if (!wallets.user) throw new Error("connect participant wallet first"); return wallets.user.signer; };

  const actOpenEnrollment   = useCallback(() => sendTx("openEnrollment",    () => cRef.current.strategy.connect(teamSgn()).openEnrollment()),   [sendTx, wallets]);
  const actFinalizeCovenants= useCallback(() => sendTx("finalizeCovenants", () => cRef.current.strategy.connect(teamSgn()).finalizeCovenants()), [sendTx, wallets]);
  const actMigrate          = useCallback(() => sendTx("migrate",           () => cRef.current.strategy.connect(teamSgn()).migrate()),           [sendTx, wallets]);
  const actFundRewards      = useCallback((amtEth) => sendTx(`fundRewards(${amtEth} ETH)`, () => cRef.current.vault.connect(teamSgn()).fundRewards({ value: ethers.parseEther(amtEth) })), [sendTx, wallets]);

  const actPokeCheckpoint = useCallback(() => {
    const who = wallets.team || wallets.user;
    if (!who) { addLog("connect a wallet first", "error"); return; }
    return sendTx("pokeCheckpoint", () => cRef.current.adapter.connect(who.signer).pokeCheckpoint(addrsRef.current.auction));
  }, [sendTx, wallets, addLog]);

  const actSubmitBid = useCallback((maxPriceEth, amtEth) => {
    return sendTx(`submitBid(${maxPriceEth} max, ${amtEth} ETH)`, () => {
      const q = bidPriceToQ96(maxPriceEth, auctionData.floor, auctionData.spacing);
      const amount = ethers.parseEther(amtEth);
      return cRef.current.cca.connect(userSgn()).submitBid(q, amount, wallets.user.address, "0x", { value: amount });
    });
  }, [sendTx, wallets, auctionData]);

  const actExitBid          = useCallback((bidId) => sendTx(`exitBid(${bidId})`,     () => cRef.current.cca.connect(userSgn()).exitBid(BigInt(bidId))),      [sendTx, wallets]);
  const actClaimBid         = useCallback((bidId) => sendTx(`claimTokens(${bidId})`, () => cRef.current.cca.connect(userSgn()).claimTokens(BigInt(bidId))), [sendTx, wallets]);
  const actEnroll           = useCallback((bps, amtEth) => sendTx(`enrollCovenant(${bps/100}%, ${amtEth} ETH)`, () => cRef.current.vault.connect(userSgn()).enrollCovenant(bps, { value: ethers.parseEther(amtEth) })), [sendTx, wallets]);
  const actUpdateCovenant   = useCallback((bps, amtEth) => sendTx(`updateCovenant(${bps/100}%, +${amtEth} ETH)`, () => cRef.current.vault.connect(userSgn()).updateCovenant(bps, { value: ethers.parseEther(amtEth) })), [sendTx, wallets]);
  const actCancelCovenant   = useCallback(() => sendTx("cancelCovenant",       () => cRef.current.vault.connect(userSgn()).cancelCovenant()),        [sendTx, wallets]);
  const actClaimRewards     = useCallback(() => sendTx("claimRewards",         () => cRef.current.vault.connect(userSgn()).claimRewards()),          [sendTx, wallets]);
  const actWithdraw         = useCallback(() => sendTx("withdrawAfterUnlock",  () => cRef.current.vault.connect(userSgn()).withdrawAfterUnlock()),   [sendTx, wallets]);
  const actEarlyExit        = useCallback(() => sendTx("earlyExit",            () => cRef.current.vault.connect(userSgn()).earlyExit()),             [sendTx, wallets]);

  const value = {
    rpcUrl, setRpcUrl, connected, netStatus,
    addrs, symbol,
    wallets, connectWallet,
    launchData, auctionData, participantRows,
    userEnrollment, userPosition, myBids,
    activityLog, currentBlock,
    connect, loadDeploymentFile,
    refreshAll, refreshUser, refreshMyBids,
    actOpenEnrollment, actFinalizeCovenants, actMigrate, actFundRewards,
    actPokeCheckpoint,
    actSubmitBid, actExitBid, actClaimBid,
    actEnroll, actUpdateCovenant, actCancelCovenant,
    actClaimRewards, actWithdraw, actEarlyExit,
  };

  return <VestaCtx.Provider value={value}>{children}</VestaCtx.Provider>;
}
