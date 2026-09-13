import { ethers } from "ethers";
import { Q96, EXPLORER } from "./constants.js";

export const fmtEth = (v) =>
  Number(ethers.formatEther(v)).toLocaleString("en-US", {
    maximumFractionDigits: 4,
  });

export const short = (a) => (a ? a.slice(0, 6) + "…" + a.slice(-4) : "—");

export const addrHref = (a) => `${EXPLORER}/address/${a}`;
export const txHref = (h) => `${EXPLORER}/tx/${h}`;

export const fmtPrice = (q) =>
  Number(ethers.formatEther((q * 10n ** 18n) / Q96)).toLocaleString("en-US", {
    maximumFractionDigits: 6,
  });

export const fmtToks = (v, dec = 18) =>
  Number(ethers.formatUnits(v, dec)).toLocaleString("en-US", {
    maximumFractionDigits: 2,
  });

export const pctToBps = (pctStr) => {
  const bps = Math.round(Number(pctStr) * 100);
  if (!Number.isFinite(bps) || bps < 0 || bps > 10000)
    throw new Error("commitment % must be 0–100");
  return bps;
};

/** Round an ETH/token price up to the auction tick grid, as Q96. */
export const bidPriceToQ96 = (ethStr, floor, spacing) => {
  const wei = ethers.parseEther(ethStr.trim());
  let q = (wei * Q96) / 10n ** 18n;
  if (q <= floor) return floor + spacing;
  const over = q - floor;
  const steps = (over + spacing - 1n) / spacing;
  return floor + steps * spacing;
};

export const secsToHuman = (s) => {
  if (s <= 0) return "unlocked ✓";
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return `${h}h ${m}m ${sec}s`;
};
