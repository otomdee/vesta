import { useState } from "react";
import { useVesta } from "../hooks/useVesta.jsx";
import Header from "../components/Header.jsx";
import Footer from "../components/Footer.jsx";
import LifecycleSidebar from "../components/LifecycleSidebar.jsx";
import { short, fmtEth, fmtToks } from "../lib/format.js";
import { EXPLORER } from "../lib/constants.js";
import styles from "./TeamPage.module.css";

export default function TeamPage() {
  const {
    addrs, symbol, wallets, connectWallet,
    launchData, auctionData, participantRows,
    activityLog, currentBlock,
    refreshAll,
    actOpenEnrollment, actFinalizeCovenants, actMigrate,
    actFundRewards, actPokeCheckpoint,
  } = useVesta();

  const [fundAmt, setFundAmt] = useState("0.1");
  const [showContractRecord, setShowContractRecord] = useState(false);

  const { lifecycle, auctionComplete, lockDuration, penaltyBps, escrowedEth, committedTokens, positionShares, rewardPot } = launchData;
  const allReady = participantRows.length > 0 && participantRows.every((r) => r.ready);
  const readyCount = participantRows.filter((r) => r.ready).length;

  // Derive active lifecycle step for sidebar (0-4)
  const sidebarStep = (() => {
    if (!auctionComplete) return 0;          // CCA bidding (or ended)
    if (!allReady)         return 2;          // exit bids
    if (lifecycle === null) return 2;
    if (lifecycle === 0 || lifecycle === 1) return 3; // finalize covenants
    if (lifecycle === 2) return 4;           // migrate
    return 4;
  })();

  const statusBadge = lifecycle === 1 ? "ENROLLMENT OPEN" : lifecycle === 2 ? "FINALIZED" : lifecycle === 3 ? "MIGRATED" : "CONFIGURED";

  return (
    <div className={styles.page}>
      <Header subtitle="TEAM WORKSPACE" />

      <main className={styles.main}>
        {/* Page title row */}
        <div className={styles.titleRow}>
          <div>
            <p className={styles.pageTag}>LAUNCH RECORD / ILLUSTRATIVE DATA</p>
            <h1 className={styles.pageTitle}>Launch operations</h1>
          </div>
          <div className={styles.addrsBlock}>
            <p>Strategy <span className={styles.mono}>{addrs.strategy ? short(addrs.strategy) : "—"}</span></p>
            <p>CCA auction <span className={styles.mono}>{addrs.auction ? short(addrs.auction) : "—"}</span></p>
          </div>
        </div>

        <div className={styles.grid}>
          {/* Sidebar */}
          <LifecycleSidebar
            activeStep={sidebarStep}
            ownerNote={wallets.team ? "Only the owner can change the launch lifecycle." : undefined}
          />

          {/* Main card */}
          <div className={styles.card}>
            {/* Card header */}
            <div className={styles.cardHeader}>
              <div>
                <p className={styles.cardTag}>CURRENT OPERATION</p>
                <h2 className={styles.cardHeading}>Review before finalization</h2>
              </div>
              <span className={styles.badge}>{statusBadge}</span>
            </div>

            {/* Warning */}
            {auctionComplete && !allReady && participantRows.length > 0 && (
              <p className={styles.warning}>
                One participant has no claimable allocation. They must exit their CCA bid, or their share may be skipped during finalization.
              </p>
            )}

            {/* Finalize row */}
            <div className={styles.finalizeRow}>
              <button
                className={styles.finalizeBtn}
                disabled={!allReady || lifecycle !== 1}
                onClick={actFinalizeCovenants}
              >
                Finalize covenants
              </button>
              <span className={styles.finalizeHint}>
                {allReady ? "Ready to finalize" : "Unavailable until all enrolled bids are exited."}
              </span>
            </div>

            {/* Participant table */}
            <div className={styles.tableSection}>
              <div className={styles.tableHeader}>
                <h3 className={styles.sectionTitle}>Participant readiness</h3>
                <span className={styles.tableCount}>{readyCount} of {participantRows.length} ready</span>
              </div>

              <table className={styles.table}>
                <thead>
                  <tr>
                    <th>PARTICIPANT</th>
                    <th>ACTIVE</th>
                    <th>COMMIT.</th>
                    <th>ETH</th>
                    <th>ALLOCATION</th>
                    <th>BID EXIT</th>
                  </tr>
                </thead>
                <tbody>
                  {participantRows.length === 0 ? (
                    <tr>
                      <td colSpan={6} className={styles.emptyRow}>No enrollments yet</td>
                    </tr>
                  ) : participantRows.map((row) => (
                    <tr key={row.address} className={!row.ready ? styles.rowAlert : ""}>
                      <td>
                        <a href={`${EXPLORER}/address/${row.address}`} target="_blank" rel="noopener noreferrer">
                          {short(row.address)}
                        </a>
                      </td>
                      <td>{row.active ? "Yes" : "No"}</td>
                      <td>{(row.commitmentBps / 100).toFixed(0)}%</td>
                      <td>{fmtEth(row.escrowedEth)}</td>
                      <td>{fmtToks(row.allocation)} {symbol}</td>
                      <td className={row.ready ? styles.ready : styles.exitNeeded}>
                        {row.ready ? "Ready" : "Exit needed"}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {/* Launch ledger + Fund rewards */}
            <div className={styles.bottomGrid}>
              <section>
                <h3 className={styles.sectionTitle}>Launch ledger</h3>
                <dl className={styles.dl}>
                  {[
                    ["Auction complete",           auctionComplete ? "Yes" : "No"],
                    ["Clearing price",             auctionData.clearingPrice > 0n ? `${fmtEth(auctionData.clearingPrice * 10n ** 18n / (2n ** 96n))} ETH` : "—"],
                    ["Escrowed ETH",               escrowedEth ? `${fmtEth(escrowedEth)} ETH` : "—"],
                    ["Committed tokens / shares",  committedTokens ? `${fmtToks(committedTokens)} / ${fmtToks(positionShares)}` : "0 / 0"],
                    ["Lock / early-exit penalty",  lockDuration ? `${Math.round(Number(lockDuration) / 86400)}d / ${penaltyBps / 100}%` : "—"],
                  ].map(([k, v]) => (
                    <div key={k} className={styles.dlRow}>
                      <dt>{k}</dt>
                      <dd>{v}</dd>
                    </div>
                  ))}
                </dl>
              </section>

              <section className={styles.fundSection}>
                <div className={styles.fundHeader}>
                  <h3 className={styles.sectionTitle}>Fund rewards</h3>
                </div>
                <p className={styles.rewardPot}>
                  Reward pot <span className={styles.mono}>{rewardPot ? `${fmtEth(rewardPot)} ETH` : "0.000 ETH"}</span>
                </p>
                <label className={styles.fundLabel}>
                  Amount (ETH)
                  <input
                    className={styles.fundInput}
                    value={fundAmt}
                    onChange={(e) => setFundAmt(e.target.value)}
                    inputMode="decimal"
                  />
                </label>
                <button className={styles.fundBtn} onClick={() => actFundRewards(fundAmt)}>
                  Fund rewards
                </button>
              </section>
            </div>

            {/* Other actions */}
            <div className={styles.otherActions}>
              <p>
                <span className={styles.actionLabel}>Open enrollment</span>
                {lifecycle === 1 ? " — already completed" : (
                  <button className={styles.inlineBtn} onClick={actOpenEnrollment}>Open enrollment</button>
                )}
              </p>
              <p>
                <span className={styles.actionLabel}>Migrate to LP</span>
                {lifecycle >= 2 ? (
                  <button className={styles.inlineBtn} onClick={actMigrate}>Migrate to LP</button>
                ) : " — available after finalization"}
              </p>
            </div>
          </div>
        </div>

        {/* Protocol & Activity */}
        <section className={styles.activity}>
          <div className={styles.activityHeader}>
            <h2 className={styles.activityTitle}>Protocol &amp; activity</h2>
            <div className={styles.activityBtns}>
              <button onClick={actPokeCheckpoint}>Poke checkpoint</button>
              <button className={styles.tealBtn} onClick={refreshAll}>Refresh launch</button>
            </div>
          </div>
          <p className={styles.activityHint}>Poke checkpoint may be signed by any connected wallet.</p>

          <div className={styles.logList}>
            {activityLog.length === 0 && (
              <span className={styles.emptyLog}>—</span>
            )}
            {activityLog.slice(0, 8).map((entry) => (
              <div key={entry.id} className={`${styles.logEntry} ${styles[entry.status]}`}>
                <span className={styles.logTime}>{entry.time}</span>
                <span className={styles.logMsg}>{entry.msg}</span>
                {entry.hash && (
                  <a
                    href={`${EXPLORER}/tx/${entry.hash}`}
                    target="_blank"
                    rel="noopener noreferrer"
                    className={styles.logHash}
                  >
                    {short(entry.hash)} ↗
                  </a>
                )}
              </div>
            ))}
          </div>

          {/* Contract record collapsible */}
          <details className={styles.contractRecord}>
            <summary>Auction &amp; contract record</summary>
            <div className={styles.contractGrid}>
              {addrs.auction && <>
                <p>End block: {auctionData.endBlock?.toString() || "—"} · Claim: {auctionData.claimBlock?.toString() || "—"}</p>
                <p>Floor: {auctionData.floor > 0n ? `${fmtEth(auctionData.floor * 10n ** 18n / 2n ** 96n)} ETH` : "—"} · Tick: {auctionData.spacing > 0n ? `${fmtEth(auctionData.spacing * 10n ** 18n / 2n ** 96n)} ETH` : "—"}</p>
                <p>Graduated: {auctionData.graduated ? "Yes" : "No"} · Bid count: {auctionData.nextBidId?.toString() || "—"}</p>
                <p>Owner: {short(addrs.owner)} · Vault: {short(addrs.vault)}</p>
                <p>Token: {symbol} · {short(addrs.token)}</p>
                <p>Auction adapter: {short(addrs.auctionAdapter)}</p>
                <p>Liquidity adapter: {short(addrs.liquidityAdapter)}</p>
              </>}
              {!addrs.auction && <p className={styles.emptyLog}>Load contracts to see record</p>}
            </div>
          </details>
        </section>
      </main>

      <Footer right="ILLUSTRATIVE LAUNCH DATA / SEPOLIA TESTNET" />
    </div>
  );
}
