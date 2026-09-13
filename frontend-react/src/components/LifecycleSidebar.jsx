import styles from "./LifecycleSidebar.module.css";

const STEPS = [
  { n: "01", label: "CCA bidding",         sub: "Bidding window" },
  { n: "02", label: "Auction ends",         sub: "End block reached" },
  { n: "03", label: "Participants exit bids", sub: "Bid exit window" },
  { n: "04", label: "Finalize covenants",   sub: "Strategy owner action" },
  { n: "05", label: "Migrate to LP",        sub: "After finalization" },
];

/** activeStep: 0-based index of the currently-active step */
export default function LifecycleSidebar({ activeStep = 2, ownerNote }) {
  return (
    <aside className={styles.sidebar}>
      <p className={styles.label}>LAUNCH LIFECYCLE</p>
      <div className={styles.steps}>
        {STEPS.map((s, i) => {
          const complete = i < activeStep;
          const active   = i === activeStep;
          return (
            <div
              key={s.n}
              className={`${styles.step} ${complete ? styles.complete : ""} ${active ? styles.active : ""}`}
            >
              <p className={styles.stepNum}>{s.n}{complete ? " / COMPLETE" : active ? " / ACTIVE" : ""}</p>
              <h3 className={styles.stepLabel}>{s.label}</h3>
              <p className={styles.stepSub}>{s.sub}</p>
            </div>
          );
        })}
      </div>

      {ownerNote && (
        <div className={styles.ownerNote}>
          <p className={styles.ownerOk}>Wallet matches strategy owner</p>
          <p className={styles.ownerSub}>{ownerNote}</p>
        </div>
      )}
    </aside>
  );
}
