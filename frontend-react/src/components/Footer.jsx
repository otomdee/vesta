import styles from "./Footer.module.css";

export default function Footer({ right }) {
  return (
    <footer className={styles.footer}>
      <span>VESTA PROTOCOL / TESTNET ONLY</span>
      {right && <span>{right}</span>}
    </footer>
  );
}
