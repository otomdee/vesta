import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { useVesta } from "../hooks/useVesta.jsx";
import Header from "../components/Header.jsx";
import Footer from "../components/Footer.jsx";
import styles from "./EntryPage.module.css";

export default function EntryPage() {
  const { connect, loadDeploymentFile, connected, rpcUrl, setRpcUrl } = useVesta();
  const navigate = useNavigate();

  const [strategy, setStrategy] = useState("");
  const [auction, setAuction]   = useState("");
  const [loading, setLoading]   = useState(false);
  const [showSettings, setShowSettings] = useState(false);

  const handleLoad = async () => {
    setLoading(true);
    const ok = await connect(strategy.trim(), auction.trim(), rpcUrl);
    setLoading(false);
    if (!ok) return;
  };

  const handleLoadFile = async () => {
    const result = await loadDeploymentFile();
    if (result) {
      setStrategy(result.strategy || "");
      setAuction(result.auction || "");
    }
  };

  const LIFECYCLE = [
    { n: "01", label: "CCA bidding",           active: true  },
    { n: "02", label: "Auction ends",           active: false },
    { n: "03", label: "Participants exit bids", active: false },
    { n: "04", label: "Team finalizes covenants", active: false },
    { n: "05", label: "Liquidity migrates to LP", active: false },
  ];

  return (
    <div className={styles.page}>
      <Header subtitle="COVENANT LIQUIDITY" />

      <main className={styles.main}>
        {/* Left sidebar */}
        <aside className={styles.aside}>
          <p className={styles.stepLabel}>01 / LAUNCH INTAKE</p>

          <h1 className={styles.hero}>
            A launch.<br />
            A shared<br />
            <span className={styles.heroAccent}>commitment.</span>
          </h1>

          <p className={styles.intro}>
            Connect a CCA auction to covenant liquidity. One launch record, two ways to participate.
          </p>

          <div className={styles.lifecycle}>
            <p className={styles.lifecycleTitle}>THE LAUNCH LIFECYCLE</p>
            <div className={styles.lifecycleSteps}>
              {LIFECYCLE.map((s) => (
                <p key={s.n} className={styles.lifecycleItem}>
                  <span className={`${styles.lifecycleNum} ${s.active ? styles.numActive : styles.numDim}`}>
                    {s.n}
                  </span>
                  {s.label}
                </p>
              ))}
            </div>
          </div>

          <p className={styles.credit}>Built for CCA · Powered by Uniswap v4</p>
        </aside>

        {/* Right card */}
        <section className={styles.card}>
          <div className={styles.cardHeader}>
            <div>
              <p className={styles.cardLabel}>CONTRACT RECORD / SEPOLIA</p>
              <h2 className={styles.cardTitle}>Open your launch</h2>
            </div>
            <span className={styles.cardId}>No. 001</span>
          </div>

          <p className={styles.cardDesc}>
            Enter the deployed contract pair to load a launch record.
          </p>

          <label className={styles.inputLabel} htmlFor="strategy">
            Strategy contract address
          </label>
          <input
            id="strategy"
            className={styles.input}
            value={strategy}
            onChange={(e) => setStrategy(e.target.value)}
            placeholder="0x… Paste strategy address"
            spellCheck={false}
          />

          <label className={styles.inputLabel} htmlFor="auction">
            CCA auction address
          </label>
          <input
            id="auction"
            className={styles.input}
            value={auction}
            onChange={(e) => setAuction(e.target.value)}
            placeholder="0x… Paste auction address"
            spellCheck={false}
          />

          <p className={styles.inputHint}>
            Vault, token, and adapters are read from the strategy contract.
          </p>

          <button
            className={styles.loadBtn}
            onClick={handleLoad}
            disabled={loading}
          >
            {loading ? "Loading…" : "Load contracts"}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M5 12h14M12 5l7 7-7 7" />
            </svg>
          </button>

          {/* Connection settings */}
          <details
            className={styles.details}
            open={showSettings}
            onToggle={(e) => setShowSettings(e.target.open)}
          >
            <summary className={styles.summary}>
              Connection settings &amp; saved deployment
            </summary>
            <label className={styles.detailsLabel}>
              Sepolia RPC URL
              <input
                className={styles.detailsInput}
                value={rpcUrl}
                onChange={(e) => setRpcUrl(e.target.value)}
                spellCheck={false}
              />
            </label>
            <button className={styles.savedBtn} onClick={handleLoadFile}>
              Load saved deployment
            </button>
          </details>

          {/* Role cards */}
          <div className={styles.roleHeader}>
            <h3 className={styles.roleTitle}>Choose your role</h3>
            <span className={styles.roleHint}>
              {connected ? "Select a view to continue" : "Load contracts to enable access"}
            </span>
          </div>

          <div className={styles.roleCards}>
            <div className={`${styles.roleCard} ${styles.roleCardDark}`}>
              <span className={styles.roleTag}>STRATEGY OWNER</span>
              <h4 className={styles.roleName}>Launch team</h4>
              <p className={styles.roleDesc}>
                Manage enrollment, finalization, liquidity, and rewards.
              </p>
              <button
                className={`${styles.roleBtn} ${styles.roleBtnDark}`}
                disabled={!connected}
                onClick={() => navigate("/team")}
              >
                Enter as team
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M7 17L17 7M7 7h10v10" />
                </svg>
              </button>
            </div>

            <div className={`${styles.roleCard} ${styles.roleCardLight}`}>
              <span className={styles.roleTagLight}>BIDDER</span>
              <h4 className={styles.roleNameLight}>Participant</h4>
              <p className={styles.roleDescLight}>
                Place bids, commit allocation, and manage your position.
              </p>
              <button
                className={`${styles.roleBtn} ${styles.roleBtnLight}`}
                disabled={!connected}
                onClick={() => navigate("/participant")}
              >
                Enter as participant
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M7 17L17 7M7 7h10v10" />
                </svg>
              </button>
            </div>
          </div>

          <p className={styles.disclaimer}>
            Team transactions require the strategy owner's wallet. No private keys are stored.
          </p>
        </section>
      </main>

      <Footer right="01 — CONTRACTS & ACCESS" />
    </div>
  );
}
