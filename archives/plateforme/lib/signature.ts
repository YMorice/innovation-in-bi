// Signature de couple d'un export, calculée dans le navigateur avant l'envoi :
// courant de broche (I Torque) ramené à `points` valeurs (maximum par tranche,
// pour garder les pics), et positions des changements d'étape.

export type Signature = { torque: number[]; stepStarts: number[]; max: number };

export function torqueSignature(bytes: Uint8Array, points = 160): Signature | null {
  const text = new TextDecoder("windows-1252").decode(bytes);
  const start = text.indexOf("*** Datas ***");
  if (start < 0) return null;
  const lines = text.slice(start).split(/\r\n|\r|\n/);
  const header = (lines[1] ?? "").split("\t").map((h) => h.trim());
  const iTorque = header.indexOf("I Torque (A)");
  const iStep = header.indexOf("Step (nb)");
  if (iTorque < 0) return null;
  const comma = /Decimal Separator[^\n]*\n[^\n]*Comma/i.test(text.slice(0, 2000));

  const torque: number[] = [];
  const steps: number[] = [];
  for (let i = 2; i < lines.length; i++) {
    const cells = lines[i].split("\t");
    if (cells.length <= iTorque || cells[iTorque].trim() === "") continue;
    const read = (s: string) => Number(comma ? s.replace(",", ".") : s);
    const t = read(cells[iTorque]);
    if (Number.isNaN(t)) continue;
    torque.push(t);
    steps.push(iStep >= 0 ? read(cells[iStep]) : 0);
  }
  if (!torque.length) return null;

  const n = Math.min(points, torque.length);
  const out: number[] = [];
  const stepStarts: number[] = [];
  for (let b = 0; b < n; b++) {
    const from = Math.floor((b * torque.length) / n);
    const to = Math.max(from + 1, Math.floor(((b + 1) * torque.length) / n));
    let m = -Infinity;
    for (let i = from; i < to; i++) m = Math.max(m, torque[i]);
    out.push(m);
    if (b > 0 && steps[from] !== steps[Math.floor(((b - 1) * torque.length) / n)]) stepStarts.push(b);
  }
  return { torque: out, stepStarts, max: Math.max(...out) };
}
