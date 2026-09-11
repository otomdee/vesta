/* Vesta Sepolia UI — vanilla JS + ethers v6 (CDN). Sepolia only, MetaMask only. */
"use strict";

const $ = (id) => document.getElementById(id);
const LIFECYCLE = ["Configured", "EnrollmentOpen", "Finalized", "Migrated", "Closed"];
const CHAIN_ID = 11155111n;
const CHAIN_HEX = "0xaa36a7";
const EXPLORER = "https://sepolia.etherscan.io";
const Q96 = 2n ** 96n;
const MAX_BID_SCAN = 500;

const ABI_STRATEGY = [
  "function owner() view returns (address)",
  "function auction() view returns (address)",
  "function vault() view returns (address)",
  "function launchToken() view returns (address)",
  "function auctionAdapter() view returns (address)",
  "function liquidityAdapter() view returns (address)",
  "function openEnrollment()",
  "function finalizeCovenants()",
  "function migrate()",
];
const ABI_VAULT = [
  "function lifecycle() view returns (uint8)",
  "function lockDuration() view returns (uint64)",
  "function earlyExitPenaltyBps() view returns (uint16)",
  "function totalEscrowedEth() view returns (uint256)",
  "function totalCommittedTokens() view returns (uint256)",
  "function totalPositionShares() view returns (uint256)",
  "function rewardPot() view returns (uint256)",
  "function participants() view returns (address[])",
  "function commitmentOf(address) view returns (uint16 commitmentBps, uint256 escrowedEth, bool active)",
  "function positionOf(address) view returns (uint256 shares, uint256 tokenId, uint256 tokenAmount, uint256 ethAmount, uint64 finalizedAt, uint64 unlockTime, bool exited)",
  "function pendingRewards(address) view returns (uint256)",
  "function enrollCovenant(uint16 commitmentBps) payable",
  "function updateCovenant(uint16 commitmentBps) payable",
  "function cancelCovenant()",
  "function fundRewards() payable",
  "function claimRewards()",
  "function withdrawAfterUnlock()",
  "function earlyExit()",
];
const ABI_ADAPTER = [
  "function pokeCheckpoint(address auction) returns (uint256)",
  "function isAuctionComplete(address) view returns (bool)",
  "function claimableAllocation(address,address) view returns (uint256)",
  "function clearingPrice(address) view returns (uint256)",
];
const ABI_CCA = [
  "function endBlock() view returns (uint64)",
  "function claimBlock() view returns (uint64)",
  "function floorPrice() view returns (uint256)",
  "function tickSpacing() view returns (uint256)",
  "function currency() view returns (address)",
  "function token() view returns (address)",
  "function isGraduated() view returns (bool)",
  "function clearingPrice() view returns (uint256)",
  "function nextBidId() view returns (uint256)",
  "function bids(uint256) view returns (uint64 startBlock, uint24 startCumulativeMps, uint64 exitedBlock, uint256 maxPrice, address owner, uint256 amountQ96, uint256 tokensFilled)",
  "function submitBid(uint256 maxPriceQ96, uint128 amount, address owner, bytes hookData) payable returns (uint256)",
  "function exitBid(uint256 bidId)",
  "function claimTokens(uint256 bidId)",
];
const ABI_LIQ = ["function POSITION_MANAGER() view returns (address)"];
const ABI_TOKEN = [
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function balanceOf(address) view returns (uint256)",
];

const S = {
  provider: null,
  addrs: {},
  c: {},
  wallets: { team: null, user: null }, // { signer, address }
  exitedAll: false,
  symbol: "tokens",
};

const fmtEth = (v) => Number(ethers.formatEther(v)).toLocaleString("en-US", { maximumFractionDigits: 4 });
const short = (a) => (a ? a.slice(0, 6) + "…" + a.slice(-4) : "—");
const addrLink = (a) => `<a href="${EXPLORER}/address/${a}" target="_blank" rel="noopener">${short(a)}</a>`;
const txLink = (h) => `<a href="${EXPLORER}/tx/${h}" target="_blank" rel="noopener">${short(h)}</a>`;
/** Q96 currency-per-token → ETH/token float string. */
const fmtPrice = (q) => Number(ethers.formatEther((q * 10n ** 18n) / Q96)).toLocaleString("en-US", { maximumFractionDigits: 6 });
/** Q96 amount → token units (assumes 18dp launch token). */
const fmtToks = (v, dec = 18) => Number(ethers.formatUnits(v, dec)).toLocaleString("en-US", { maximumFractionDigits: 2 });

function kv(el, rows) {
  el.innerHTML = rows.map(([k, v]) => `<div><span>${k}</span><span>${v}</span></div>`).join("");
}

function log(html, cls) {
  const li = document.createElement("li");
  if (cls) li.className = cls;
  li.innerHTML = `<span class="muted">${new Date().toLocaleTimeString()}</span> ${html}`;
  $("txlog").prepend(li);
}

async function send(label, fn) {
  log(`⏳ ${label}…`);
  try {
    const tx = await fn();
    const rc = await tx.wait();
    if (rc.status === 0) throw new Error("tx reverted");
    log(`✅ ${label} — <span class="ok">${txLink(rc.hash)}</span>`, "ok");
    await refreshAll();
    return rc;
  } catch (e) {
    const msg = (e && e.shortMessage) || (e && e.reason) || (e && e.message) || String(e);
    log(`❌ ${label} — <span class="fail">${String(msg).slice(0, 300)}</span>`, "fail");
    return null;
  }
}

// ---------- connection ----------

async function loadDeploymentFile() {
  try {
    const r = await fetch("./src/generated/deployment.sepolia.json", { cache: "no-store" });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const j = await r.json();
    if (!j.strategy) throw new Error("missing strategy key");
    $("addrStrategy").value = j.strategy;
    if (j.auctionAddress) $("addrAuction").value = j.auctionAddress;
    log(`📄 deployment.sepolia.json loaded (strategy ${short(j.strategy)})`, "ok");
  } catch (e) {
    log(`❌ could not load deployment.sepolia.json (${e.message}) — broadcast DeploySepolia, then paste addresses`, "fail");
  }
}

async function connect() {
  try {
    S.provider = new ethers.JsonRpcProvider($("rpcUrl").value.trim());
    const net = await S.provider.getNetwork();
    const block = await S.provider.getBlockNumber();
    const st = $("netStatus");
    if (net.chainId !== CHAIN_ID) {
      st.className = "netstatus err";
      st.textContent = `wrong chain ${net.chainId} — need Sepolia 11155111`;
      log(`❌ RPC is chain ${net.chainId}, not Sepolia. Fix the RPC URL.`, "fail");
      return;
    }
    st.className = "netstatus ok";
    st.textContent = `Sepolia · block ${block}`;

    const strategyAddr = $("addrStrategy").value.trim();
    const auctionAddr = $("addrAuction").value.trim();
    if (!ethers.isAddress(strategyAddr) || strategyAddr === ethers.ZeroAddress) {
      throw new Error("strategy address missing — broadcast DeploySepolia first");
    }
    if (!ethers.isAddress(auctionAddr) || auctionAddr === ethers.ZeroAddress) {
      throw new Error("auction address missing");
    }
    S.addrs = { strategy: strategyAddr, auction: auctionAddr };
    const strategy = new ethers.Contract(strategyAddr, ABI_STRATEGY, S.provider);
    S.addrs.vault = await strategy.vault();
    S.addrs.token = await strategy.launchToken();
    S.addrs.auctionAdapter = await strategy.auctionAdapter();
    S.addrs.liquidityAdapter = await strategy.liquidityAdapter();
    S.addrs.owner = await strategy.owner();
    if (S.addrs.vault === ethers.ZeroAddress) throw new Error("no vault at strategy — wrong network?");

    S.c = {
      strategy,
      vault: new ethers.Contract(S.addrs.vault, ABI_VAULT, S.provider),
      adapter: new ethers.Contract(S.addrs.auctionAdapter, ABI_ADAPTER, S.provider),
      cca: new ethers.Contract(auctionAddr, ABI_CCA, S.provider),
      token: new ethers.Contract(S.addrs.token, ABI_TOKEN, S.provider),
    };
    try {
      const pm = new ethers.Contract(S.addrs.liquidityAdapter, ABI_LIQ, S.provider);
      S.addrs.positionManager = await pm.POSITION_MANAGER();
    } catch { S.addrs.positionManager = null; }
    try { S.symbol = await S.c.token.symbol(); } catch { S.symbol = "tokens"; }

    kv($("contractAddrs"), [
      ["owner", addrLink(S.addrs.owner)],
      ["vault", addrLink(S.addrs.vault)],
      ["token", addrLink(S.addrs.token)],
      ["auction adapter", addrLink(S.addrs.auctionAdapter)],
      ["liquidity adapter", addrLink(S.addrs.liquidityAdapter)],
      ["auction", addrLink(S.addrs.auction)],
    ]);
    await refreshAll();
    log("🔌 connected to Sepolia", "ok");
  } catch (e) {
    $("netStatus").className = "netstatus err";
    $("netStatus").textContent = "connection failed";
    log(`❌ connect failed — ${(e.shortMessage || e.message || e)}`, "fail");
  }
}

// ---------- wallets (MetaMask only) ----------

async function metamaskProvider() {
  if (!window.ethereum) throw new Error("no wallet found (install MetaMask)");
  await window.ethereum.request({ method: "eth_requestAccounts" });
  const bp = new ethers.BrowserProvider(window.ethereum);
  try {
    const net = await bp.getNetwork();
    if (net.chainId !== CHAIN_ID) {
      try {
        await window.ethereum.request({
          method: "wallet_switchEthereumChain", params: [{ chainId: CHAIN_HEX }],
        });
      } catch (e) {
        if (e && e.code === 4902) {
          await window.ethereum.request({
            method: "wallet_addEthereumChain",
            params: [{
              chainId: CHAIN_HEX, chainName: "Sepolia",
              nativeCurrency: { name: "Sepolia ETH", symbol: "ETH", decimals: 18 },
              rpcUrls: ["https://ethereum-sepolia-rpc.publicnode.com"],
              blockExplorerUrls: [EXPLORER],
            }],
          });
        } else throw e;
      }
    }
  } catch (e) {
    if (/no wallet/.test(e.message)) throw e;
    throw new Error("approve the Sepolia network switch in your wallet first");
  }
  return new ethers.BrowserProvider(window.ethereum);
}

async function useMetaMask(role) {
  try {
    const bp = await metamaskProvider();
    const signer = await bp.getSigner();
    const address = await signer.getAddress();
    S.wallets[role] = { signer, address };
    await paintWallet(role);
    log(`👛 ${role} = ${short(address)}`, "ok");
  } catch (e) {
    log(`❌ wallet failed — ${(e.shortMessage || e.message || e)}`, "fail");
  }
}

async function paintWallet(role) {
  const w = S.wallets[role];
  const box = role === "team" ? $("walletTeam") : $("walletUser");
  if (!w) return void kv(box, [["status", "not connected"]]);
  let bal = "—";
  try { bal = fmtEth(await S.provider.getBalance(w.address)) + " ETH"; } catch { /* offline */ }
  kv(box, [["address", addrLink(w.address)], ["balance", bal]]);
}

const actingUser = () => ($("userAddr").value.trim() || (S.wallets.user && S.wallets.user.address) || "");
const teamVault = () => {
  if (!S.wallets.team) throw new Error("connect the team wallet first");
  return S.c.vault.connect(S.wallets.team.signer);
};
const userVault = () => {
  if (!S.wallets.user) throw new Error("connect the participant wallet first");
  return S.c.vault.connect(S.wallets.user.signer);
};

// ---------- reads ----------

async function refreshAll() {
  if (!S.provider || !S.c.vault) return;
  await Promise.all([paintWallet("team"), paintWallet("user")]);
  await refreshAuction();
  await refreshLaunch();
  await refreshUser();
  tickCountdown();
}

async function refreshAuction() {
  const c = S.c.cca;
  const [end, claim, grad, price, next, floor, spacing, cur] = await Promise.all([
    c.endBlock(), c.claimBlock(), c.isGraduated(), c.clearingPrice(),
    c.nextBidId(), c.floorPrice(), c.tickSpacing(), c.currency(),
  ]);
  const blk = await S.provider.getBlockNumber();
  const curSym = cur === ethers.ZeroAddress ? "ETH" : short(cur);
  kv($("auctionInfo"), [
    ["auction", addrLink(S.addrs.auction)],
    ["currency", curSym],
    ["block", `${blk} (end ${end}, claim ${claim})`],
    ["graduated", String(grad)],
    ["clearing price", `${fmtPrice(price)} ETH/token`],
    ["floor / tick", `${fmtPrice(floor)} / ${fmtPrice(spacing)} ETH`],
    ["bids so far", next.toString()],
  ]);
  S.auctionMeta = { end: Number(end), claim: Number(claim), floor: BigInt(floor), spacing: BigInt(spacing) };

  // My bids for the acting address.
  const u = actingUser();
  if (!ethers.isAddress(u)) {
    $("myBids").innerHTML = '<span class="muted">enter an acting address in §4 to list bids</span>';
    return;
  }
  const n = Number(next);
  const scan = Math.min(n, MAX_BID_SCAN);
  let rows = "";
  for (let id = 0; id < scan; ++id) {
    const b = await c.bids(id);
    if (b.owner.toLowerCase() !== u.toLowerCase()) continue;
    const exited = b.exitedBlock !== 0n;
    rows += `<tr><td>${id}</td><td>${fmtPrice(b.maxPrice)}</td>` +
      `<td>${fmtEth((b.amountQ96 * 10n ** 18n) / Q96)}</td>` +
      `<td>${fmtToks(b.tokensFilled)}</td><td>${exited}</td>` +
      `<td>${exited ? `<button type="button" data-claim="${id}">Claim</button>`
        : `<button type="button" data-exit="${id}">Exit</button>`}</td></tr>`;
  }
  if (n > MAX_BID_SCAN) rows += `<tr><td colspan="6" class="muted">…${n - MAX_BID_SCAN} more bids not scanned</td></tr>`;
  $("myBids").innerHTML = rows
    ? `<table><tr><th>id</th><th>max price</th><th>amount</th><th>filled (${S.symbol})</th><th>exited</th><th></th></tr>${rows}</table>`
    : '<span class="muted">no bids for this address yet</span>';
}

async function refreshLaunch() {
  const v = S.c.vault;
  const [lc, lock, bps, esc, com, shares, pot, complete, price] = await Promise.all([
    v.lifecycle(), v.lockDuration(), v.earlyExitPenaltyBps(), v.totalEscrowedEth(),
    v.totalCommittedTokens(), v.totalPositionShares(), v.rewardPot(),
    S.c.adapter.isAuctionComplete(S.addrs.auction), S.c.adapter.clearingPrice(S.addrs.auction),
  ]);
  kv($("launchInfo"), [
    ["lifecycle", `${LIFECYCLE[Number(lc)]} (${lc})`],
    ["auction complete", String(complete)],
    ["clearing price", `${fmtPrice(price)} ETH/token`],
    ["lock duration", `${Number(lock)}s (${(Number(lock) / 86400).toFixed(1)}d)`],
    ["early-exit penalty", `${Number(bps) / 100}%`],
    ["escrowed ETH", `${fmtEth(esc)} ETH`],
    ["committed tokens", `${fmtToks(com)} ${S.symbol}`],
    ["position shares", `${fmtEth(shares)}`],
    ["reward pot", `${fmtEth(pot)} ETH`],
  ]);
  const steps = ["Bidding", "Ended", "Exited", "Finalized", "Migrated"];
  const blk = await S.provider.getBlockNumber();
  const ended = S.auctionMeta ? blk >= S.auctionMeta.end : false;

  const list = await v.participants();
  let exitedAll = complete && list.length > 0;
  let rows = "";
  for (const p of list) {
    const [cm, alloc] = await Promise.all([
      v.commitmentOf(p), S.c.adapter.claimableAllocation(S.addrs.auction, p),
    ]);
    if (cm.active && alloc === 0n) exitedAll = false;
    rows += `<tr><td>${addrLink(p)}</td><td>${cm.active}</td><td>${Number(cm.commitmentBps) / 100}%</td>` +
      `<td>${fmtEth(cm.escrowedEth)}</td><td>${fmtToks(alloc)}</td><td>${alloc > 0n}</td></tr>`;
  }
  S.exitedAll = exitedAll;
  $("participants").innerHTML = rows
    ? `<table><tr><th>bidder</th><th>active</th><th>bps</th><th>escrow</th><th>allocation</th><th>exited</th></tr>${rows}</table>`
    : '<span class="muted">no enrollments yet</span>';

  const warn = $("finalizeWarn");
  if (complete && list.length > 0 && !exitedAll) {
    warn.hidden = false;
    warn.textContent = "⚠️ Some enrolled bidders read 0 allocation — they must Exit their CCA bids before Finalize, or their share is skipped.";
  } else warn.hidden = true;

  // Labels have an extra "Exited" step vs the vault enum, so shift finalized/migrated by one.
  const stage = !ended ? 0 : !exitedAll ? 1 : Number(lc) + 1;
  const labels = ["Bidding", "Ended", "Exited", "Finalized", "Migrated"];
  $("timeline").innerHTML = labels
    .map((s, i) => `<li class="${i <= stage ? "done" : ""}">${s}</li>`)
    .join("");
}

async function refreshUser() {
  const u = actingUser();
  if (!ethers.isAddress(u)) {
    kv($("userInfo"), [["acting address", "invalid — enter an address"]]);
    kv($("positionInfo"), [["position", "—"]]);
    return;
  }
  const v = S.c.vault;
  const [cm, alloc, pos, pend, tbal, ebal] = await Promise.all([
    v.commitmentOf(u), S.c.adapter.claimableAllocation(S.addrs.auction, u),
    v.positionOf(u), v.pendingRewards(u),
    S.c.token.balanceOf(u), S.provider.getBalance(u),
  ]);
  const committed = (alloc * BigInt(cm.commitmentBps)) / 10000n;
  kv($("userInfo"), [
    ["address", addrLink(u)],
    ["enrolled", String(cm.active)],
    ["commitment", `${Number(cm.commitmentBps) / 100}%`],
    ["escrowed", `${fmtEth(cm.escrowedEth)} ETH`],
    ["CCA allocation", `${fmtToks(alloc)} ${S.symbol}`],
    ["→ covenant (locked)", `${fmtToks(committed)} ${S.symbol}`],
    ["→ liquid (claimable)", `${fmtToks(alloc - committed)} ${S.symbol}`],
    ["wallet balances", `${fmtToks(tbal)} ${S.symbol} · ${fmtEth(ebal)} ETH`],
  ]);
  const hasPos = pos.shares > 0n;
  const nft = S.addrs.positionManager && pos.tokenId > 0n
    ? `<a href="${EXPLORER}/token/${S.addrs.positionManager}?a=${pos.tokenId}" target="_blank" rel="noopener">${pos.tokenId}</a>`
    : pos.tokenId.toString();
  kv($("positionInfo"), hasPos ? [
    ["shares (reward weight)", fmtEth(pos.shares)],
    ["position NFT id", nft],
    ["locked tokens", `${fmtToks(pos.tokenAmount)} ${S.symbol}`],
    ["locked ETH", `${fmtEth(pos.ethAmount)} ETH`],
    ["unlock", new Date(Number(pos.unlockTime) * 1000).toLocaleString()],
    ["countdown", `<span data-unlock="${pos.unlockTime}">…</span>`],
    ["exited", String(pos.exited)],
    ["pending rewards", `${fmtEth(pend)} ETH`],
  ] : [["position", "none yet — bid + enroll, then team finalizes + migrates"]]);
}

function tickCountdown() {
  document.querySelectorAll("[data-unlock]").forEach((el) => {
    const s = Number(el.dataset.unlock) - Math.floor(Date.now() / 1000);
    el.textContent = s <= 0 ? "unlocked ✓" : `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m ${s % 60}s`;
  });
}
setInterval(tickCountdown, 1000);

// ---------- CCA actions ----------

/** Round an ETH/token price up to the auction tick grid, as Q96. */
function bidPriceToQ96(ethStr, floor, spacing) {
  const wei = ethers.parseEther(ethStr.trim());
  let q = (wei * Q96) / 10n ** 18n;
  if (q <= floor) return floor + spacing;
  const over = q - floor;
  const steps = (over + spacing - 1n) / spacing;
  return floor + steps * spacing;
}

async function actSubmitBid() {
  try {
    if (!S.wallets.user) throw new Error("connect the participant wallet first");
    if (!S.auctionMeta) throw new Error("auction info not loaded");
    const q = bidPriceToQ96($("bidMaxPrice").value, S.auctionMeta.floor, S.auctionMeta.spacing);
    const amount = ethers.parseEther($("bidAmount").value.trim());
    if (amount <= 0n) throw new Error("amount must be > 0");
    if (amount > (1n << 128n) - 1n) throw new Error("amount too large");
    const me = S.wallets.user.address;
    await send(`submitBid(max=${fmtPrice(q)} ETH, ${fmtEth(amount)} ETH)`, () =>
      S.c.cca.connect(S.wallets.user.signer).submitBid(q, amount, me, "0x", { value: amount }));
  } catch (e) {
    log(`❌ bid failed — ${(e.shortMessage || e.message || e)}`, "fail");
  }
}

async function actExit(bidId) {
  if (!S.wallets.user) return log("❌ connect the participant wallet first", "fail");
  const r = await send(`exitBid(${bidId})`, () =>
    S.c.cca.connect(S.wallets.user.signer).exitBid(BigInt(bidId)));
  if (!r) {
    log("ℹ️ exitBid reverted — partially-filled bids need <code>exitPartiallyFilledBid</code> with checkpoint hints (resolve via cast/forge, see README)", "");
  }
}

async function actClaimBid(bidId) {
  if (!S.wallets.user) return log("❌ connect the participant wallet first", "fail");
  await send(`claimTokens(${bidId})`, () =>
    S.c.cca.connect(S.wallets.user.signer).claimTokens(BigInt(bidId)));
}

async function actPoke() {
  const who = S.wallets.team || S.wallets.user;
  if (!who) return log("❌ connect a wallet first", "fail");
  await send("pokeCheckpoint", () =>
    S.c.adapter.connect(who.signer).pokeCheckpoint(S.addrs.auction));
}

// ---------- team / user actions ----------

async function actOpen() {
  await send("openEnrollment", () => S.c.strategy.connect(S.wallets.team.signer).openEnrollment());
}
async function actFinalize() {
  await send("finalizeCovenants", () => S.c.strategy.connect(S.wallets.team.signer).finalizeCovenants());
}
async function actMigrate() {
  await send("migrate", () => S.c.strategy.connect(S.wallets.team.signer).migrate());
}
async function actFund() {
  const amt = $("fundAmount").value.trim();
  await send(`fundRewards(${amt} ETH)`, () =>
    teamVault().fundRewards({ value: ethers.parseEther(amt) }));
}
const pctToBps = () => {
  const bps = Math.round(Number($("enrollBpsPct").value) * 100);
  if (!Number.isFinite(bps) || bps < 0 || bps > 10000) throw new Error("commitment % must be 0–100");
  return bps;
};
async function actEnroll() {
  try {
    const bps = pctToBps();
    const eth = $("enrollEth").value.trim();
    await send(`enrollCovenant(${bps / 100}%, ${eth} ETH)`, () =>
      userVault().enrollCovenant(bps, { value: ethers.parseEther(eth) }));
  } catch (e) { log(`❌ ${e.message}`, "fail"); }
}
async function actUpdate() {
  try {
    const bps = pctToBps();
    const eth = $("enrollEth").value.trim();
    await send(`updateCovenant(${bps / 100}%, +${eth} ETH)`, () =>
      userVault().updateCovenant(bps, { value: ethers.parseEther(eth) }));
  } catch (e) { log(`❌ ${e.message}`, "fail"); }
}
async function actCancel() {
  await send("cancelCovenant", () => userVault().cancelCovenant());
}
async function actClaim() {
  await send("claimRewards", () => userVault().claimRewards());
}
async function actWithdraw() {
  await send("withdrawAfterUnlock", () => userVault().withdrawAfterUnlock());
}
async function actEarlyExit() {
  if (!confirm("Exit early and pay the penalty?")) return;
  await send("earlyExit", () => userVault().earlyExit());
}

// ---------- wiring ----------

$("btnConnect").addEventListener("click", connect);
$("btnLoadDeployment").addEventListener("click", loadDeploymentFile);
$("btnRefresh").addEventListener("click", refreshAll);
$("btnRefreshAuction").addEventListener("click", async () => { await refreshAuction(); await refreshLaunch(); });
document.querySelectorAll("[data-metamask]").forEach((b) =>
  b.addEventListener("click", () => useMetaMask(b.dataset.metamask)));
$("btnSubmitBid").addEventListener("click", actSubmitBid);
$("btnPoke").addEventListener("click", actPoke);
$("myBids").addEventListener("click", (e) => {
  const t = e.target;
  if (t.dataset.exit !== undefined) actExit(t.dataset.exit);
  if (t.dataset.claim !== undefined) actClaimBid(t.dataset.claim);
});
$("btnOpenEnrollment").addEventListener("click", () => {
  if (!S.wallets.team) return log("❌ connect the team wallet first", "fail");
  actOpen();
});
$("btnFinalize").addEventListener("click", () => {
  if (!S.wallets.team) return log("❌ connect the team wallet first", "fail");
  actFinalize();
});
$("btnMigrate").addEventListener("click", () => {
  if (!S.wallets.team) return log("❌ connect the team wallet first", "fail");
  actMigrate();
});
$("btnFund").addEventListener("click", () => {
  if (!S.wallets.team) return log("❌ connect the team wallet first", "fail");
  actFund();
});
$("btnEnroll").addEventListener("click", actEnroll);
$("btnUpdate").addEventListener("click", actUpdate);
$("btnCancel").addEventListener("click", actCancel);
$("btnClaim").addEventListener("click", actClaim);
$("btnWithdraw").addEventListener("click", actWithdraw);
$("btnEarlyExit").addEventListener("click", actEarlyExit);
$("btnUseWallet").addEventListener("click", () => {
  if (S.wallets.user) {
    $("userAddr").value = S.wallets.user.address;
    refreshUser();
    refreshAuction();
  }
});
if (typeof ethers === "undefined") {
  document.getElementById("netStatus").textContent = "ethers.js CDN failed to load — check network";
}
