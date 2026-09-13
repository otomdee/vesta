import { useNavigate } from "react-router-dom";
import { useVesta } from "../hooks/useVesta.jsx";
import { short } from "../lib/format.js";
import styles from "./Header.module.css";

export default function Header({ subtitle }) {
  const { netStatus, wallets, connectWallet, connected } = useVesta();
  const navigate = useNavigate();

  const handleWalletClick = async () => {
    const role = window.location.pathname.includes("team") ? "team" : "user";
    await connectWallet(role);
  };

  const connectedWallet = wallets.team || wallets.user;

  return (
    <header className={styles.header}>
      <div className={styles.brand} onClick={() => navigate("/")} style={{ cursor: "pointer" }}>
        <span className={styles.logo}>
          VESTA<span className={styles.dot}>.</span>
        </span>
        <span className={styles.subtitle}>{subtitle || "COVENANT LIQUIDITY"}</span>
      </div>

      <div className={styles.actions}>
        <span className={`${styles.netStatus} ${netStatus.ok ? styles.ok : ""}`}>
          <span className={styles.dot2}>●</span>&nbsp;&nbsp;&nbsp;{netStatus.text}
        </span>

        {connectedWallet ? (
          <button className={styles.walletBtn} onClick={handleWalletClick}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M20 7H4a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2z" />
              <path d="M16 12h2" />
            </svg>
            {short(connectedWallet.address)}
          </button>
        ) : (
          <button className={styles.connectBtn} onClick={handleWalletClick}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M20 7H4a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2z" />
              <path d="M16 12h2" />
            </svg>
            Connect wallet
          </button>
        )}
      </div>
    </header>
  );
}
