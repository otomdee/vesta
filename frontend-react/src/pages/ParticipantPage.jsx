import { useState, useEffect } from "react";
import { useVesta } from "../hooks/useVesta.jsx";
import Header from "../components/Header.jsx";
import Footer from "../components/Footer.jsx";
import LifecycleSidebar from "../components/LifecycleSidebar.jsx";
import { short, fmtEth, fmtToks, fmtPrice, pctToBps, secsToHuman } from "../lib/format.js";
import { EXPLORER } from "../lib/constants.js";
import styles from "./ParticipantPage.module.css";

export default function ParticipantPage() {
  const {
    addrs, symbol, wallets, connectWallet,
    launchData, auctionData,
    userEnrollment, userPosition, myBids,
    activityLog, currentBlock,
    refreshAll, refreshUser, refreshMyBids,
    actPokeCheckpoint,
    actSubmitBid, actExitBid, actClaimBid,
    actEnroll, actUpdateCovenant, actCancelCovenant,
    actClaimRewards, actWithdraw, actEarlyExit,
  } = useVesta();

  const [userAddr, setUserAddr]   = useState("");
  const [maxPrice, setMaxPrice]   = useState("0.002");
  const [bidAmt, setBidAmt]       = useState("0.1");
  const [commitPct, setCommitPct] = useState("40");
  const [escrowEth, setEscrowEth] = useState("0.1");
  const [countdown, setCountdown] = useState("");

  // Countdown ticker
  useEffect(() => {
    if (!userPosition?.unlockTime) return;
    const tick = () => {
      const s = Number(userPosition.unlockTime) - Math.floor(Date.now() / 1000);
      setCountdown(secsToHuman(s));
    };
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, [userPosition?.unlockTime]);

  const handleUseWallet = () => {
    if (wallets.user) {
      setUserAddr(wallets.user.address);
      refreshUser(wallets.user.address);
      refreshMyBids(wallets.user.address);
    }
  };

  const handleRefreshUser = () => {
    if (userAddr) {
      refreshUser(userAddr);
      refreshMyBids(userAddr);
    }
  };

  const { lifecycle, auctionComplete, lockDuration, penaltyBps, rewardPot } = launchData;

  // Sidebar step for participant POV
  const sidebarStep = (() => {
    if (!auctionComplete) return 0;
    if (userEnrollment?.allocation === 0n || !userEnrollment?.allocation) return 2;
    if (lifecycle === 0 || lifecycle === 1) return 3;
    if (lifecycle === 2) return 4;
    return 4;
  })();

  const hasPosition = userPosition && userPosition.shares > 0n;

  return (
    <div className={styles.page}>
      <Header subtitle="PARTICIPANT WORKSPACE" />

      <main className={styles.main}>
        {/* Page title row */}
        <div className={styles.titleRow}>
          <div>
            <p className={styles.pageTag}>PARTICIPANT RECORD / SEPOLIA</p>
            <h1 className={styles.pageTitle}>Your position</h1>
          </div>
          <div className={styles.walletRow}>
            {wallets.user ? (
              <button className={styles.walletBadge} onClick={() => connectWallet("user")}>
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M20 7H4a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2z" />
                  <path d="M16 12h2" />
                </svg>
                {short(wallets.user.address)}
              </button>
            ) : (
              <button className={styles.connectWalletBtn} onClick={() => connectWallet("user")}>
                Connect participant wallet
              </button>
            )}
            {wallets.user && (
              <button className={styles.useWalletBtn} onClick={handleUseWallet}>
                Load my data
              </button>
            )}
          </div>
        </div>

        <div className={styles.grid}>
          {/* Sidebar */}
          <LifecycleSidebar activeStep={sidebarStep} />

          {/* Main panel */}
          <div className={styles.panels}>

            {/* ── Panel 1: CCA Bid ── */}
            <div className={styles.card}>
              <div className={styles.cardHeader}>
                <div>
                  <p className={styles.cardTag}>CCA AUCTION</p>
                  <h2 className={styles.cardHeading}>Place a bid</h2>
                </div>
                <div className={styles.auctionMeta}>
                  <span>Block {currentBlock || "—"}</span>
                  <span className={auctionData.graduated ? styles.greenPill : styles.dimPill}>
                    {auctionData.graduated ? "Graduated" : "Active"}
                  </span>
                </div>
              </div>

              <div className={styles.bidGrid}>
                <label className={styles.inputLabel}>
                  Max price (ETH/token)
                  <input
                    className={styles.input}
                    value={maxPrice}
                    onChange={(e) => setMaxPrice(e.target.value)}
                    inputMode="decimal"
                  />
                </label>
                <label className={styles.inputLabel}>
                  Amount (ETH)
                  <input
                    className={styles.input}
                    value={bidAmt}
                    onChange={(e) => setBidAmt(e.target.value)}
                    inputMode="decimal"
                  />
                </label>
              </div>

              <p className={styles.inputHint}>
                Max price is rounded up to the auction's tick grid. Floor: {auctionData.floor > 0n ? `${fmtEth(auctionData.floor * 10n**18n / 2n**96n)} ETH` : "—"} · Tick: {auctionData.spacing > 0n ? `${fmtEth(auctionData.spacing * 10n**18n / 2n**96n)} ETH` : "—"}
              </p>

              <button
                className={styles.primaryBtn}
                disabled={!wallets.user}
                onClick={() => actSubmitBid(maxPrice, bidAmt)}
              >
                Submit bid
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M5 12h14M12 5l7 7-7 7" />
                </svg>
              </button>

              {/* My bids table */}
              {myBids.length > 0 && (
                <div className={styles.bidsSection}>
                  <h3 className={styles.subTitle}>My bids</h3>
                  <div className={styles.tableWrapper}>
                  <table className={styles.bidsTable}>
                    <thead>
                      <tr>
                        <th>ID</th>
                        <th>MAX PRICE</th>
                        <th>AMOUNT</th>
                        <th>FILLED ({symbol})</th>
                        <th>EXITED</th>
                        <th></th>
                      </tr>
                    </thead>
                    <tbody>
                      {myBids.map((b) => (
                        <tr key={b.id}>
                          <td>{b.id}</td>
                          <td>{fmtEth(b.maxPrice * 10n**18n / 2n**96n)}</td>
                          <td>{fmtEth((b.amountQ96 * 10n**18n) / 2n**96n)}</td>
                          <td>{fmtToks(b.tokensFilled)}</td>
                          <td>{b.exited ? "Yes" : "No"}</td>
                          <td>
                            {b.exited ? (
                              <button className={styles.tableBtn} onClick={() => actClaimBid(b.id)}>Claim</button>
                            ) : (
                              <button className={styles.tableBtn} onClick={() => actExitBid(b.id)}>Exit</button>
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                  </div>
                </div>
              )}

              <div className={styles.pokRow}>
                <button className={styles.ghostBtn} onClick={actPokeCheckpoint}>
                  Poke checkpoint (anyone)
                </button>
                <button className={styles.ghostBtn} onClick={() => { refreshMyBids(userAddr); }}>
                  Refresh bids
                </button>
              </div>
            </div>

            {/* ── Panel 2: Covenant Enrollment ── */}
            <div className={styles.card}>
              <div className={styles.cardHeader}>
                <div>
                  <p className={styles.cardTag}>COVENANT ENROLLMENT</p>
                  <h2 className={styles.cardHeading}>Commit your allocation</h2>
                </div>
                {userEnrollment?.active && (
                  <span className={styles.enrolledBadge}>ENROLLED</span>
                )}
              </div>

              {/* User address picker */}
              <div className={styles.addrRow}>
                <label className={styles.inputLabel} style={{ flex: 1 }}>
                  Acting address
                  <input
                    className={styles.input}
                    value={userAddr}
                    onChange={(e) => setUserAddr(e.target.value)}
                    placeholder="defaults to participant wallet"
                    spellCheck={false}
                  />
                </label>
                <button className={styles.ghostBtnSm} onClick={handleRefreshUser}>
                  Refresh
                </button>
              </div>

              <div className={styles.enrollGrid}>
                <label className={styles.inputLabel}>
                  Commitment (% of allocation)
                  <input
                    className={styles.input}
                    value={commitPct}
                    onChange={(e) => setCommitPct(e.target.value)}
                    inputMode="decimal"
                  />
                </label>
                <label className={styles.inputLabel}>
                  ETH to escrow
                  <input
                    className={styles.input}
                    value={escrowEth}
                    onChange={(e) => setEscrowEth(e.target.value)}
                    inputMode="decimal"
                  />
                </label>
              </div>

              <div className={styles.enrollBtns}>
                <button
                  className={styles.primaryBtn}
                  disabled={!wallets.user}
                  onClick={() => actEnroll(pctToBps(commitPct), escrowEth)}
                >
                  Enroll
                </button>
                <button
                  className={styles.secondaryBtn}
                  disabled={!wallets.user}
                  onClick={() => actUpdateCovenant(pctToBps(commitPct), escrowEth)}
                >
                  Update
                </button>
                <button
                  className={styles.dangerBtn}
                  disabled={!wallets.user}
                  onClick={actCancelCovenant}
                >
                  Cancel + refund
                </button>
              </div>

              {/* Enrollment status */}
              {userEnrollment && (
                <dl className={styles.dl}>
                  {[
                    ["Enrolled",     userEnrollment.active ? "Yes" : "No"],
                    ["Commitment",   `${(userEnrollment.commitmentBps / 100).toFixed(0)}%`],
                    ["Escrowed ETH", userEnrollment.escrowedEth ? `${fmtEth(userEnrollment.escrowedEth)} ETH` : "—"],
                    ["CCA allocation", userEnrollment.allocation ? `${fmtToks(userEnrollment.allocation)} ${symbol}` : "—"],
                    ["→ Covenant (locked)", userEnrollment.allocation ? `${fmtToks((userEnrollment.allocation * BigInt(userEnrollment.commitmentBps)) / 10000n)} ${symbol}` : "—"],
                    ["→ Liquid (claimable)", userEnrollment.allocation ? `${fmtToks(userEnrollment.allocation - (userEnrollment.allocation * BigInt(userEnrollment.commitmentBps)) / 10000n)} ${symbol}` : "—"],
                  ].map(([k, v]) => (
                    <div key={k} className={styles.dlRow}>
                      <dt>{k}</dt>
                      <dd>{v}</dd>
                    </div>
                  ))}
                </dl>
              )}

              <p className={styles.inputHint}>
                Lock duration: {lockDuration ? `${Math.round(Number(lockDuration) / 86400)}d` : "—"} · Early-exit penalty: {penaltyBps ? `${penaltyBps / 100}%` : "—"}
              </p>
            </div>

            {/* ── Panel 3: Position & Rewards ── */}
            <div className={styles.card}>
              <div className={styles.cardHeader}>
                <div>
                  <p className={styles.cardTag}>LP POSITION &amp; REWARDS</p>
                  <h2 className={styles.cardHeading}>
                    {hasPosition ? "Your covenant position" : "No position yet"}
                  </h2>
                </div>
                {rewardPot > 0n && (
                  <div className={styles.rewardPot}>
                    <span className={styles.rewardPotLabel}>Reward pot</span>
                    <span className={styles.rewardPotVal}>{fmtEth(rewardPot)} ETH</span>
                  </div>
                )}
              </div>

              {!hasPosition && (
                <p className={styles.emptyState}>
                  Bid in the CCA, enroll a covenant, then wait for the team to finalize and migrate to see your LP position here.
                </p>
              )}

              {hasPosition && (
                <>
                  <dl className={styles.dl}>
                    {[
                      ["Shares (reward weight)", fmtEth(userPosition.shares)],
                      ["Position NFT ID", userPosition.tokenId > 0n ? (
                        <a key="nft" href={`${EXPLORER}/token/${addrs.positionManager}?a=${userPosition.tokenId}`} target="_blank" rel="noopener noreferrer">{userPosition.tokenId.toString()}</a>
                      ) : "—"],
                      ["Locked tokens", `${fmtToks(userPosition.tokenAmount)} ${symbol}`],
                      ["Locked ETH",    `${fmtEth(userPosition.ethAmount)} ETH`],
                      ["Unlock",        new Date(Number(userPosition.unlockTime) * 1000).toLocaleString()],
                      ["Countdown",     countdown || "—"],
                      ["Exited",        userPosition.exited ? "Yes" : "No"],
                      ["Pending rewards", `${fmtEth(userPosition.pendingRewards)} ETH`],
                    ].map(([k, v]) => (
                      <div key={k} className={styles.dlRow}>
                        <dt>{k}</dt>
                        <dd>{v}</dd>
                      </div>
                    ))}
                  </dl>

                  <div className={styles.positionBtns}>
                    <button
                      className={styles.primaryBtn}
                      disabled={!wallets.user}
                      onClick={actClaimRewards}
                    >
                      Claim rewards
                    </button>
                    <button
                      className={styles.secondaryBtn}
                      disabled={!wallets.user}
                      onClick={actWithdraw}
                    >
                      Withdraw after unlock
                    </button>
                    <button
                      className={styles.dangerBtn}
                      disabled={!wallets.user}
                      onClick={() => {
                        if (window.confirm("Exit early and pay the penalty?")) actEarlyExit();
                      }}
                    >
                      Early exit ({penaltyBps / 100}% penalty)
                    </button>
                  </div>
                </>
              )}
            </div>
          </div>
        </div>

        {/* Activity log */}
        <section className={styles.activity}>
          <div className={styles.activityHeader}>
            <h2 className={styles.activityTitle}>Activity</h2>
            <button className={styles.tealBtn} onClick={refreshAll}>Refresh all</button>
          </div>
          <div className={styles.logList}>
            {activityLog.length === 0 && (
              <span className={styles.emptyLog}>—</span>
            )}
            {activityLog.slice(0, 6).map((entry) => (
              <div key={entry.id} className={`${styles.logEntry} ${styles[entry.status]}`}>
                <span className={styles.logTime}>{entry.time}</span>
                <span className={styles.logMsg}>{entry.msg}</span>
                {entry.hash && (
                  <a href={`${EXPLORER}/tx/${entry.hash}`} target="_blank" rel="noopener noreferrer" className={styles.logHash}>
                    {short(entry.hash)} ↗
                  </a>
                )}
              </div>
            ))}
          </div>
        </section>
      </main>

      <Footer right="02 — PARTICIPANT VIEW" />
    </div>
  );
}
