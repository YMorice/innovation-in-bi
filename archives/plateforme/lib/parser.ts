// Découpage d'un export de cycle de perçage (.xls texte tabulé) en document pour la
// fonction SQL import_cycle. Même contrat que ingestion/charger_cycles.py : toute
// évolution doit être faite des deux côtés.

import { createHash } from "node:crypto";

type Kind = "text" | "num" | "int" | "bool" | "date";
type Mapping = Record<string, [string, Kind]>;
type Json = null | boolean | number | string | Json[] | { [k: string]: Json };
type Row = Record<string, Json>;

const BOX_FIELDS: Mapping = {
  "BOX Name": ["box_name", "text"],
  "BOX Type": ["box_type", "text"],
  "BOX STSE": ["box_stse", "text"],
  "BOX Customer Info": ["customer_info", "text"],
  "BOX Production Date": ["production_date", "date"],
  "BOX Power Supply Limit": ["power_supply_limit", "num"],
  "BOX Lub Pump Coef.": ["lub_pump_coef", "num"],
};
const BOX_CYCLE_FIELDS: Mapping = {
  "BOX Release": ["box_release", "text"],
  "BOX Firmware Version": ["box_firmware_version", "text"],
  "BOX Maintenance Date": ["box_maintenance_date", "date"],
  "BOX Operation Time": ["box_operation_time", "int"],
  "Pset Default Selection": ["pset_default_selection", "bool"],
};
const MOTOR_FIELDS: Mapping = {
  "Motor Name": ["motor_name", "text"],
  "Motor Type": ["motor_type", "text"],
  "Motor STSE": ["motor_stse", "text"],
  "Motor SN": ["motor_sn", "text"],
  "Motor M2 Ratio": ["m2_ratio", "num"],
  "Motor M1 CW Ratio": ["m1_cw_ratio", "num"],
  "Motor M1 CCW Ratio": ["m1_ccw_ratio", "num"],
  "Motor Winch Limit": ["winch_limit", "num"],
};
const MOTOR_CYCLE_FIELDS: Mapping = { "Motor Operation Time": ["motor_operation_time", "int"] };
const HEAD_FIELDS: Mapping = {
  "Head TAG UID": ["head_tag_uid", "text"],
  "Head Name": ["head_name", "text"],
  "Head Type": ["head_type", "text"],
  "Head M1 Ratio": ["m1_ratio", "num"],
  "Head M2 Ratio": ["m2_ratio", "num"],
  "Customer Info": ["customer_info", "text"],
};
const HEAD_CYCLE_FIELDS: Mapping = {
  "Head Global Counter": ["head_global_counter", "int"],
  "Head Local Counter 1": ["head_local_counter_1", "int"],
  "Head Local Counter 2": ["head_local_counter_2", "int"],
};
const PSET_FIELDS: Mapping = {
  "Pset Type": ["pset_type", "text"],
  "Pset Nb.": ["pset_nb", "int"],
  Version: ["pset_version", "int"],
};
const CYCLE_PARAM_FIELDS: Mapping = {
  "Max cycles Limit 1": ["max_cycles_limit_1", "int"],
  "Max cycles Limit 2": ["max_cycles_limit_2", "int"],
  "CC Pressure": ["cc_pressure", "num"],
  "Max Stroke (mm)": ["max_stroke_mm", "num"],
  "Vacuum Delay (ms)": ["vacuum_delay_ms", "num"],
  "Vacuum Flow min (m/s)": ["vacuum_flow_min_ms", "num"],
  "Retract Rotation Speed (rpm)": ["retract_rotation_speed_rpm", "num"],
  "Retract Feed (m/s)": ["retract_feed_ms", "num"],
  "Disable Abort": ["disable_abort", "bool"],
  Comment: ["comment", "text"],
  "Cutting tool breakage On/Off": ["tool_breakage_on", "bool"],
  "Cutting tool breakage DEP (mm)": ["tool_breakage_dep_mm", "num"],
  "Cutting tool breakage Thrust (A)": ["tool_breakage_thrust_a", "num"],
  "Cutting tool breakage Torque (A)": ["tool_breakage_torque_a", "num"],
  "Lub Preload Time (s)": ["lub_preload_time_s", "num"],
  "Lub Preload Lub Air": ["lub_preload_lub_air", "num"],
  "Lub Preload Lub Flow": ["lub_preload_lub_flow", "num"],
  "Lub Preload Timeout (s)": ["lub_preload_timeout_s", "num"],
};
const RESULT_FIELDS: Mapping = {
  "Cycle Time (s)": ["cycle_time_s", "num"],
  "Distance (mm)": ["distance_mm", "num"],
  "Cycle OK": ["cycle_ok", "bool"],
};
const PROGRAM_STEP_FIELDS: Mapping = {
  "Step Nb": ["step_nb", "int"],
  "Step On/Off": ["step_on", "bool"],
  "Stroke (mm)": ["stroke_mm", "num"],
  RPM: ["rpm", "num"],
  "Feed (mm/s)": ["feed_mm_s", "num"],
  "Feed (mm/tr)": ["feed_mm_tr", "num"],
  "Thrust Max (A)": ["thrust_max_a", "num"],
  "Torque Max (A)": ["torque_max_a", "num"],
  "Thrust Min (A)": ["thrust_min_a", "num"],
  "Torque Min (A)": ["torque_min_a", "num"],
  "Thrust Safety (A)": ["thrust_safety_a", "num"],
  "Torque Safety (A)": ["torque_safety_a", "num"],
  "Gap (mm)": ["gap_mm", "num"],
  "Peck (nb)": ["peck_nb", "num"],
  "Delay (ms)": ["delay_ms", "num"],
  "Stroke Limit (A)": ["stroke_limit_a", "num"],
  "Thrust Limit (A)": ["thrust_limit_a", "num"],
  "Torque Limit (A)": ["torque_limit_a", "num"],
  "LUB AIR": ["lub_air", "num"],
  "LUB FLOW": ["lub_flow", "num"],
  Vacuum: ["vacuum", "num"],
  Material: ["material", "num"],
};
const STEP_RESULT_FIELDS: Mapping = {
  "Step Number": ["step_nb", "int"],
  "Stop Code": ["stop_code", "int"],
  "Duration (s)": ["duration_s", "num"],
  "Distance M1": ["distance_m1", "num"],
  "Distance M2": ["distance_m2", "num"],
  "M1 Max Amp": ["m1_max_amp", "num"],
  "M2 Max Amp": ["m2_max_amp", "num"],
  "M1 No Load Amp": ["m1_no_load_amp", "num"],
  "M2 No Load Amp": ["m2_no_load_amp", "num"],
  "Gap Max (mm)": ["gap_max_mm", "num"],
};
const SAMPLE_FIELDS: Record<string, string> = {
  "Position (mm)": "position_mm",
  "I Torque (A)": "i_torque_a",
  "I Thrust (A)": "i_thrust_a",
  "I Torque Empty (A)": "i_torque_empty_a",
  "I Thrust Empty (A)": "i_thrust_empty_a",
  "Step (nb)": "step_nb",
  "Stop code": "stop_code",
  "Mem Torque min (A)": "mem_torque_min_a",
  "Mem Thrust min (A)": "mem_thrust_min_a",
  "Torque Power (W)": "torque_power_w",
  "Gap Length (mm)": "gap_length_mm",
};
const GENERAL_FIELDS = new Set([
  "Version", "Date", "Sample Rate (Hz)", "Drilling Cycle ID",
  "Decimal Separator separator", "Decimal Separator", "Synthetic",
]);
const KNOWN_SECTIONS = new Set([
  "General Infos", "Control Box Datas", "Motor Datas", "Head Datas", "Pset",
  "Cycle Parameters", "Program", "Results", "Step Results", "Datas",
]);

export class ParseError extends Error {}

function decode(raw: Uint8Array): string {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(raw);
  } catch {
    return new TextDecoder("windows-1252").decode(raw);
  }
}

function splitSections(text: string): Map<string, string[][]> {
  const sections = new Map<string, string[][]>();
  let current: string[][] | null = null;
  for (const line of text.split(/\r\n|\r|\n/)) {
    const cells = line.split("\t");
    while (cells.length && cells[cells.length - 1] === "") cells.pop();
    const first = cells.length ? cells[0].trim() : "";
    if (first.startsWith("***") && first.endsWith("***")) {
      current = [];
      sections.set(first.replace(/^[* ]+|[* ]+$/g, "").trim(), current);
    } else if (current) {
      current.push(cells);
    }
  }
  return sections;
}

// Section en paires (ligne d'en-têtes, ligne de valeurs). « Comment » est seul sur
// sa ligne et sa valeur (la ligne suivante) peut être vide.
function keyValues(rows: string[][] = []): Record<string, string> {
  const out: Record<string, string> = {};
  let i = 0;
  while (i < rows.length) {
    const header = rows[i];
    if (!header.length) {
      i += 1;
      continue;
    }
    const values = rows[i + 1] ?? [];
    if (header.length === 1 && header[0].trim() === "Comment") {
      out.Comment = values.join("\t").trim();
      i += 2;
      continue;
    }
    header.forEach((label, j) => {
      out[label.trim()] = j < values.length ? values[j].trim() : "";
    });
    i += 2;
  }
  return out;
}

function tableRows(rows: string[][] = []): [string[], string[][]] {
  const filled = rows.filter((r) => r.length);
  if (!filled.length) return [[], []];
  return [filled[0].map((h) => h.trim()), filled.slice(1)];
}

function zipRow(header: string[], row: string[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (let j = 0; j < Math.min(header.length, row.length); j++) out[header[j]] = row[j].trim();
  return out;
}

class Converter {
  private comma: boolean;
  constructor(decimalSeparator: string) {
    this.comma = decimalSeparator.trim().toLowerCase().startsWith("comma");
  }
  num(v: string): number | null {
    let s = v.trim();
    if (this.comma) s = s.replaceAll(",", ".");
    if (s === "" || ["inf", "-inf", "nan"].includes(s.toLowerCase())) return null;
    const n = Number(s);
    if (Number.isNaN(n)) throw new ParseError(`valeur numérique illisible : « ${v} »`);
    return n === 0 ? 0 : n; // -0 -> 0
  }
  int(v: string): number | null {
    const n = this.num(v);
    return n === null ? null : Math.round(n);
  }
  bool(v: string): boolean | null {
    const s = v.trim().toLowerCase();
    if (["true", "on", "yes"].includes(s)) return true;
    if (["false", "off", "no"].includes(s)) return false;
    const n = this.num(v);
    return n === null ? null : n !== 0;
  }
  text(v: string): string | null {
    return v.trim() || null;
  }
  date(v: string): string | null {
    const s = v.trim();
    if (!s) return null;
    const m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(s); // export : JJ/MM/AAAA
    if (!m) throw new ParseError(`date illisible : « ${v} »`);
    return `${m[3]}-${m[2].padStart(2, "0")}-${m[1].padStart(2, "0")}`;
  }
  get(kind: Kind, v: string): Json {
    return this[kind](v);
  }
}

function pick(values: Record<string, string>, mapping: Mapping, conv: Converter, used: Set<string>): Row {
  const out: Row = {};
  for (const [label, [column, kind]] of Object.entries(mapping)) {
    if (label in values) {
      out[column] = conv.get(kind, values[label]);
      used.add(label);
    }
  }
  return out;
}

function leftovers(values: Record<string, string>, used: Set<string>): Row {
  const out: Row = {};
  for (const [k, v] of Object.entries(values)) if (!used.has(k) && v !== "") out[k] = v;
  return out;
}

export type CycleDocument = Row & {
  source_file: string;
  source_sha256: string;
  is_synthetic: boolean;
  samples: Record<string, (number | null)[]>;
};

export function sha256Hex(raw: Uint8Array): string {
  return createHash("sha256").update(raw).digest("hex");
}

export function parseExport(raw: Uint8Array, fileName: string): CycleDocument {
  const sections = splitSections(decode(raw));
  for (const required of ["General Infos", "Control Box Datas", "Datas"]) {
    if (!sections.has(required)) {
      throw new ParseError(`section « ${required} » absente : ce n'est pas un export de cycle`);
    }
  }

  const general = keyValues(sections.get("General Infos"));
  const conv = new Converter(general["Decimal Separator separator"] || general["Decimal Separator"] || "Point");
  for (const f of ["Version", "Date", "Sample Rate (Hz)", "Drilling Cycle ID"]) {
    if (!general[f]) throw new ParseError(`champ « ${f} » absent`);
  }
  const d = /^(\d{4}-\d{2}-\d{2}):(\d{2}:\d{2}:\d{2})$/.exec(general.Date);
  if (!d) throw new ParseError(`date du cycle illisible : « ${general.Date} »`);

  const doc: Row = {
    source_file: fileName,
    source_sha256: sha256Hex(raw),
    file_version: conv.int(general.Version),
    started_at: `${d[1]}T${d[2]}`,
    sample_rate_hz: conv.int(general["Sample Rate (Hz)"]),
    drilling_cycle_id: conv.int(general["Drilling Cycle ID"]),
    is_synthetic: (general.Synthetic ?? "").trim().toLowerCase() === "true",
  };
  const extra: Row = leftovers(general, GENERAL_FIELDS);

  const box = keyValues(sections.get("Control Box Datas"));
  if (!box["BOX SN"]) throw new ParseError("BOX SN absent");
  let used = new Set(["BOX SN"]);
  const boxRow: Row = { ...pick(box, BOX_FIELDS, conv, used), box_sn: conv.text(box["BOX SN"]) };
  Object.assign(doc, pick(box, BOX_CYCLE_FIELDS, conv, used));
  boxRow.extra = leftovers(box, used);
  doc.box = boxRow;

  const motor = keyValues(sections.get("Motor Datas"));
  used = new Set();
  const motorRow: Row | null = motor["Motor Name"] ? pick(motor, MOTOR_FIELDS, conv, used) : null;
  Object.assign(doc, pick(motor, MOTOR_CYCLE_FIELDS, conv, used));
  if (motorRow) {
    motorRow.motor_sn = motorRow.motor_sn || "";
    motorRow.extra = leftovers(motor, used);
  }
  doc.motor = motorRow;

  const head = keyValues(sections.get("Head Datas"));
  used = new Set();
  const headRow: Row | null = head["Head TAG UID"] ? pick(head, HEAD_FIELDS, conv, used) : null;
  Object.assign(doc, pick(head, HEAD_CYCLE_FIELDS, conv, used));
  if (headRow) headRow.extra = leftovers(head, used);
  doc.head = headRow;

  const pset = keyValues(sections.get("Pset"));
  const params = keyValues(sections.get("Cycle Parameters"));
  used = new Set();
  const program: Row = pick(pset, PSET_FIELDS, conv, used);
  const programExtra = leftovers(pset, used);
  used = new Set();
  Object.assign(program, pick(params, CYCLE_PARAM_FIELDS, conv, used));
  program.extra = { ...programExtra, ...leftovers(params, used) };

  let [header, rows] = tableRows(sections.get("Program"));
  program.steps = rows.map((row) => {
    const values = zipRow(header, row);
    const u = new Set<string>();
    const step = pick(values, PROGRAM_STEP_FIELDS, conv, u);
    step.extra = leftovers(values, u);
    return step;
  });
  doc.program = program;

  const results = keyValues(sections.get("Results"));
  used = new Set();
  Object.assign(doc, pick(results, RESULT_FIELDS, conv, used));
  Object.assign(extra, leftovers(results, used));

  [header, rows] = tableRows(sections.get("Step Results"));
  doc.step_results = rows.map((row) => {
    const values = zipRow(header, row);
    const u = new Set<string>();
    const step = pick(values, STEP_RESULT_FIELDS, conv, u);
    step.extra = leftovers(values, u);
    return step;
  });

  [header, rows] = tableRows(sections.get("Datas"));
  const missing = Object.keys(SAMPLE_FIELDS).filter((label) => !header.includes(label));
  if (missing.length) throw new ParseError(`colonnes de mesure absentes : ${missing.join(", ")}`);
  const samples: Record<string, (number | null)[]> = {};
  for (const [label, column] of Object.entries(SAMPLE_FIELDS)) {
    const p = header.indexOf(label);
    samples[column] = rows.map((row) => (p < row.length ? conv.num(row[p]) : null));
  }
  const unmapped = header.filter((h) => !(h in SAMPLE_FIELDS));
  if (unmapped.length) extra.unmapped_sample_columns = unmapped;

  const unknown: Row = {};
  for (const [name, rs] of sections) if (!KNOWN_SECTIONS.has(name)) unknown[name] = rs;
  if (Object.keys(unknown).length) extra.unknown_sections = unknown;
  doc.extra = extra;

  return { ...doc, samples } as CycleDocument;
}
