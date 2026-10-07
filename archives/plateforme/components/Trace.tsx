import type { Signature } from "@/lib/signature";

// Courbe de couple d'un cycle ; les traits verticaux marquent les changements d'étape.
export function Trace({ signature, muted }: { signature: Signature | null; muted?: boolean }) {
  const w = 176;
  const h = 34;
  if (!signature) return <span className="trace trace-vide" aria-hidden="true" />;
  const { torque, stepStarts } = signature;
  const top = Math.max(signature.max, 1);
  const x = (i: number) => (i / Math.max(torque.length - 1, 1)) * w;
  const y = (v: number) => h - 2 - (Math.max(v, 0) / top) * (h - 4);
  const line = torque.map((v, i) => `${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(" ");
  return (
    <svg
      className={muted ? "trace trace-muted" : "trace"}
      viewBox={`0 0 ${w} ${h}`}
      role="img"
      aria-label={`Courbe de couple, maximum ${signature.max.toFixed(1)} A`}
    >
      {stepStarts.map((i) => (
        <line key={i} x1={x(i)} x2={x(i)} y1={0} y2={h} className="trace-etape" />
      ))}
      <polyline points={`0,${h} ${line} ${w},${h}`} className="trace-aire" />
      <polyline points={line} className="trace-ligne" />
    </svg>
  );
}
