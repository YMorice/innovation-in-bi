"""Import en masse des exports de cycles de perçage (.xls texte tabulé) dans Supabase.

Usage :
    python charger_cycles.py fichier1.xls [dossier/ ...] [--parallele 4]

Lit SUPABASE_URL et SUPABASE_SECRET_KEY dans l'environnement ou dans le .env du
projet. Passe uniquement par HTTPS (fonction import_cycle de l'API Supabase) : pas
besoin d'accès direct à la base. Chaque fichier est importé dans sa propre
transaction ; un fichier déjà importé ou un cycle déjà connu est ignoré.

Le découpage du fichier est le même que celui de l'app web
(app/index.html, IMPORT dans le worker) : toute évolution doit être faite des deux côtés.
"""

import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

# libellé de l'export -> (colonne, type)
BOX_FIELDS = {
    "BOX Name": ("box_name", "text"),
    "BOX Type": ("box_type", "text"),
    "BOX STSE": ("box_stse", "text"),
    "BOX Customer Info": ("customer_info", "text"),
    "BOX Production Date": ("production_date", "date"),
    "BOX Power Supply Limit": ("power_supply_limit", "num"),
    "BOX Lub Pump Coef.": ("lub_pump_coef", "num"),
}
BOX_CYCLE_FIELDS = {  # relevés propres au cycle
    "BOX Release": ("box_release", "text"),
    "BOX Firmware Version": ("box_firmware_version", "text"),
    "BOX Maintenance Date": ("box_maintenance_date", "date"),
    "BOX Operation Time": ("box_operation_time", "int"),
    "Pset Default Selection": ("pset_default_selection", "bool"),
}
MOTOR_FIELDS = {
    "Motor Name": ("motor_name", "text"),
    "Motor Type": ("motor_type", "text"),
    "Motor STSE": ("motor_stse", "text"),
    "Motor SN": ("motor_sn", "text"),
    "Motor M2 Ratio": ("m2_ratio", "num"),
    "Motor M1 CW Ratio": ("m1_cw_ratio", "num"),
    "Motor M1 CCW Ratio": ("m1_ccw_ratio", "num"),
    "Motor Winch Limit": ("winch_limit", "num"),
}
MOTOR_CYCLE_FIELDS = {"Motor Operation Time": ("motor_operation_time", "int")}
HEAD_FIELDS = {
    "Head TAG UID": ("head_tag_uid", "text"),
    "Head Name": ("head_name", "text"),
    "Head Type": ("head_type", "text"),
    "Head M1 Ratio": ("m1_ratio", "num"),
    "Head M2 Ratio": ("m2_ratio", "num"),
    "Customer Info": ("customer_info", "text"),
}
HEAD_CYCLE_FIELDS = {
    "Head Global Counter": ("head_global_counter", "int"),
    "Head Local Counter 1": ("head_local_counter_1", "int"),
    "Head Local Counter 2": ("head_local_counter_2", "int"),
}
PSET_FIELDS = {
    "Pset Type": ("pset_type", "text"),
    "Pset Nb.": ("pset_nb", "int"),
    "Version": ("pset_version", "int"),
}
CYCLE_PARAM_FIELDS = {
    "Max cycles Limit 1": ("max_cycles_limit_1", "int"),
    "Max cycles Limit 2": ("max_cycles_limit_2", "int"),
    "CC Pressure": ("cc_pressure", "num"),
    "Max Stroke (mm)": ("max_stroke_mm", "num"),
    "Vacuum Delay (ms)": ("vacuum_delay_ms", "num"),
    "Vacuum Flow min (m/s)": ("vacuum_flow_min_ms", "num"),
    "Retract Rotation Speed (rpm)": ("retract_rotation_speed_rpm", "num"),
    "Retract Feed (m/s)": ("retract_feed_ms", "num"),
    "Disable Abort": ("disable_abort", "bool"),
    "Comment": ("comment", "text"),
    "Cutting tool breakage On/Off": ("tool_breakage_on", "bool"),
    "Cutting tool breakage DEP (mm)": ("tool_breakage_dep_mm", "num"),
    "Cutting tool breakage Thrust (A)": ("tool_breakage_thrust_a", "num"),
    "Cutting tool breakage Torque (A)": ("tool_breakage_torque_a", "num"),
    "Lub Preload Time (s)": ("lub_preload_time_s", "num"),
    "Lub Preload Lub Air": ("lub_preload_lub_air", "num"),
    "Lub Preload Lub Flow": ("lub_preload_lub_flow", "num"),
    "Lub Preload Timeout (s)": ("lub_preload_timeout_s", "num"),
}
RESULT_FIELDS = {
    "Cycle Time (s)": ("cycle_time_s", "num"),
    "Distance (mm)": ("distance_mm", "num"),
    "Cycle OK": ("cycle_ok", "bool"),
}
PROGRAM_STEP_FIELDS = {
    "Step Nb": ("step_nb", "int"),
    "Step On/Off": ("step_on", "bool"),
    "Stroke (mm)": ("stroke_mm", "num"),
    "RPM": ("rpm", "num"),
    "Feed (mm/s)": ("feed_mm_s", "num"),
    "Feed (mm/tr)": ("feed_mm_tr", "num"),
    "Thrust Max (A)": ("thrust_max_a", "num"),
    "Torque Max (A)": ("torque_max_a", "num"),
    "Thrust Min (A)": ("thrust_min_a", "num"),
    "Torque Min (A)": ("torque_min_a", "num"),
    "Thrust Safety (A)": ("thrust_safety_a", "num"),
    "Torque Safety (A)": ("torque_safety_a", "num"),
    "Gap (mm)": ("gap_mm", "num"),
    "Peck (nb)": ("peck_nb", "num"),
    "Delay (ms)": ("delay_ms", "num"),
    "Stroke Limit (A)": ("stroke_limit_a", "num"),
    "Thrust Limit (A)": ("thrust_limit_a", "num"),
    "Torque Limit (A)": ("torque_limit_a", "num"),
    "LUB AIR": ("lub_air", "num"),
    "LUB FLOW": ("lub_flow", "num"),
    "Vacuum": ("vacuum", "num"),
    "Material": ("material", "num"),
}
STEP_RESULT_FIELDS = {
    "Step Number": ("step_nb", "int"),
    "Stop Code": ("stop_code", "int"),
    "Duration (s)": ("duration_s", "num"),
    "Distance M1": ("distance_m1", "num"),
    "Distance M2": ("distance_m2", "num"),
    "M1 Max Amp": ("m1_max_amp", "num"),
    "M2 Max Amp": ("m2_max_amp", "num"),
    "M1 No Load Amp": ("m1_no_load_amp", "num"),
    "M2 No Load Amp": ("m2_no_load_amp", "num"),
    "Gap Max (mm)": ("gap_max_mm", "num"),
}
SAMPLE_FIELDS = {
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
}
GENERAL_FIELDS = {"Version", "Date", "Sample Rate (Hz)", "Drilling Cycle ID",
                  "Decimal Separator separator", "Decimal Separator", "Synthetic"}
KNOWN_SECTIONS = {"General Infos", "Control Box Datas", "Motor Datas", "Head Datas", "Pset",
                  "Cycle Parameters", "Program", "Results", "Step Results", "Datas"}


# ---------------------------------------------------------------- découpage

def decode(raw: bytes) -> str:
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("cp1252")


def split_sections(text: str) -> dict[str, list[list[str]]]:
    """Découpe le fichier en sections « *** Nom *** » -> lignes de cellules."""
    sections: dict[str, list[list[str]]] = {}
    current = None
    for line in text.splitlines():
        cells = line.split("\t")
        while cells and cells[-1] == "":
            cells.pop()
        first = cells[0].strip() if cells else ""
        if first.startswith("***") and first.endswith("***"):
            current = first.strip("* ").strip()
            sections[current] = []
        elif current is not None:
            sections[current].append(cells)
    return sections


def key_values(rows: list[list[str]]) -> dict[str, str]:
    """Section en paires (ligne d'en-têtes, ligne de valeurs).

    « Comment » est seul sur sa ligne et sa valeur (la ligne suivante) peut être vide.
    """
    out: dict[str, str] = {}
    i = 0
    while i < len(rows):
        header = rows[i]
        if not header:
            i += 1
            continue
        values = rows[i + 1] if i + 1 < len(rows) else []
        if [h.strip() for h in header] == ["Comment"]:
            out["Comment"] = "\t".join(values).strip()
            i += 2
            continue
        for j, label in enumerate(header):
            out[label.strip()] = values[j].strip() if j < len(values) else ""
        i += 2
    return out


def table_rows(rows: list[list[str]]) -> tuple[list[str], list[list[str]]]:
    rows = [r for r in rows if r]
    if not rows:
        return [], []
    return [h.strip() for h in rows[0]], rows[1:]


class Converter:
    def __init__(self, decimal_separator: str):
        self.comma = decimal_separator.strip().lower().startswith("comma")

    def num(self, v: str):
        v = v.strip()
        if self.comma:
            v = v.replace(",", ".")
        if v == "" or v.lower() in ("inf", "-inf", "nan"):
            return None
        n = float(v)
        # 5,000 -> 5 : même écriture JSON que l'app web (empreinte du programme)
        return int(n) if n.is_integer() else n

    def int(self, v: str):
        n = self.num(v)
        return None if n is None else int(round(n))

    def bool(self, v: str):
        v = v.strip().lower()
        if v in ("true", "on", "yes"):
            return True
        if v in ("false", "off", "no"):
            return False
        n = self.num(v)
        return None if n is None else n != 0

    @staticmethod
    def text(v: str):
        v = v.strip()
        return v or None

    @staticmethod
    def date(v: str):
        v = v.strip()
        if not v:
            return None
        return datetime.strptime(v, "%d/%m/%Y").date().isoformat()  # export : JJ/MM/AAAA


def pick(values: dict[str, str], mapping: dict, conv: Converter, used: set) -> dict:
    out = {}
    for label, (column, kind) in mapping.items():
        if label in values:
            out[column] = getattr(conv, kind)(values[label])
            used.add(label)
    return out


def leftovers(values: dict[str, str], used: set) -> dict:
    return {k: v for k, v in values.items() if k not in used and v != ""}


def parse(raw: bytes, file_name: str) -> dict:
    """Fichier d'export -> document attendu par la fonction SQL import_cycle."""
    sections = split_sections(decode(raw))
    for required in ("General Infos", "Control Box Datas", "Datas"):
        if required not in sections:
            raise ValueError(f"section « {required} » absente : ce n'est pas un export de cycle")

    general = key_values(sections["General Infos"])
    conv = Converter(general.get("Decimal Separator separator")
                     or general.get("Decimal Separator") or "Point")

    doc = {
        "source_file": file_name,
        "source_sha256": hashlib.sha256(raw).hexdigest(),
        "file_version": conv.int(general["Version"]),
        "started_at": datetime.strptime(general["Date"], "%Y-%m-%d:%H:%M:%S").isoformat(),
        "sample_rate_hz": conv.int(general["Sample Rate (Hz)"]),
        "drilling_cycle_id": conv.int(general["Drilling Cycle ID"]),
        "is_synthetic": general.get("Synthetic", "").strip().lower() == "true",
    }
    extra = leftovers(general, GENERAL_FIELDS)

    box = key_values(sections["Control Box Datas"])
    used = {"BOX SN"}
    if not box.get("BOX SN"):
        raise ValueError("BOX SN absent")
    doc["box"] = pick(box, BOX_FIELDS, conv, used) | {"box_sn": conv.text(box["BOX SN"])}
    doc |= pick(box, BOX_CYCLE_FIELDS, conv, used)
    doc["box"]["extra"] = leftovers(box, used)

    motor = key_values(sections.get("Motor Datas", []))
    used = set()
    doc["motor"] = pick(motor, MOTOR_FIELDS, conv, used) if motor.get("Motor Name") else None
    doc |= pick(motor, MOTOR_CYCLE_FIELDS, conv, used)
    if doc["motor"] is not None:
        doc["motor"]["motor_sn"] = doc["motor"].get("motor_sn") or ""
        doc["motor"]["extra"] = leftovers(motor, used)

    head = key_values(sections.get("Head Datas", []))
    used = set()
    doc["head"] = pick(head, HEAD_FIELDS, conv, used) if head.get("Head TAG UID") else None
    doc |= pick(head, HEAD_CYCLE_FIELDS, conv, used)
    if doc["head"] is not None:
        doc["head"]["extra"] = leftovers(head, used)

    pset = key_values(sections.get("Pset", []))
    params = key_values(sections.get("Cycle Parameters", []))
    used = set()
    program = pick(pset, PSET_FIELDS, conv, used)
    program_extra = leftovers(pset, used)
    used = set()
    program |= pick(params, CYCLE_PARAM_FIELDS, conv, used)
    program["extra"] = program_extra | leftovers(params, used)

    header, rows = table_rows(sections.get("Program", []))
    program["steps"] = []
    for row in rows:
        values = dict(zip(header, (c.strip() for c in row)))
        used = set()
        step = pick(values, PROGRAM_STEP_FIELDS, conv, used)
        step["extra"] = leftovers(values, used)
        program["steps"].append(step)
    doc["program"] = program

    results = key_values(sections.get("Results", []))
    used = set()
    doc |= pick(results, RESULT_FIELDS, conv, used)
    extra |= leftovers(results, used)

    header, rows = table_rows(sections.get("Step Results", []))
    doc["step_results"] = []
    for row in rows:
        values = dict(zip(header, (c.strip() for c in row)))
        used = set()
        step = pick(values, STEP_RESULT_FIELDS, conv, used)
        step["extra"] = leftovers(values, used)
        doc["step_results"].append(step)

    header, rows = table_rows(sections["Datas"])
    missing = [label for label in SAMPLE_FIELDS if label not in header]
    if missing:
        raise ValueError(f"colonnes de mesure absentes : {', '.join(missing)}")
    doc["samples"] = {}
    for label, column in SAMPLE_FIELDS.items():
        p = header.index(label)
        doc["samples"][column] = [conv.num(row[p]) if p < len(row) else None for row in rows]
    unmapped = [h for h in header if h not in SAMPLE_FIELDS]
    if unmapped:
        extra["unmapped_sample_columns"] = unmapped

    unknown = {name: rows for name, rows in sections.items() if name not in KNOWN_SECTIONS}
    if unknown:
        extra["unknown_sections"] = unknown
    doc["extra"] = extra
    return doc


# ---------------------------------------------------------------- envoi

def load_dotenv():
    env_file = Path(__file__).resolve().parent.parent / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


class Api:
    def __init__(self, url: str, key: str):
        self.url = url.rstrip("/")
        self.headers = {"apikey": key, "Content-Type": "application/json"}
        if key.startswith("eyJ"):  # ancienne clé service_role (JWT)
            self.headers["Authorization"] = f"Bearer {key}"

    def post(self, path: str, body, prefer: str | None = None):
        headers = dict(self.headers)
        if prefer:
            headers["Prefer"] = prefer
        req = urllib.request.Request(f"{self.url}/rest/v1/{path}", method="POST",
                                     data=json.dumps(body).encode(), headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                data = resp.read()
                return json.loads(data) if data else None
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")
            try:
                detail = json.loads(detail).get("message", detail)
            except ValueError:
                pass
            raise RuntimeError(f"HTTP {exc.code} : {detail}") from None


def import_file(api: Api, path: Path) -> tuple[str, str]:
    raw = path.read_bytes()
    log = {"file_name": path.name, "sha256": hashlib.sha256(raw).hexdigest(),
           "size_bytes": len(raw), "source": "cli"}
    try:
        doc = parse(raw, path.name)
        log["is_synthetic"] = doc["is_synthetic"]
        result = api.post("rpc/import_cycle", {"p": doc})
        status = result["status"]
        message = (f"cycle {result['cycle_id']}, {result['samples']} mesures"
                   if status == "importé" else result.get("message", ""))
        log |= {"status": status, "message": message, "cycle_id": result.get("cycle_id")}
    except Exception as exc:  # un fichier en erreur n'arrête pas le lot
        status, message = "erreur", str(exc)
        log |= {"status": status, "message": message}
    try:
        api.post("import_file", log, prefer="return=minimal")
    except Exception as exc:
        message += f" (journal non écrit : {exc})"
    return status, message


def expand(paths: list[str]) -> list[Path]:
    files = []
    for p in map(Path, paths):
        files.extend(sorted(p.glob("*.xls")) if p.is_dir() else [p])
    return files


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("chemins", nargs="+", help="fichiers .xls ou dossiers")
    parser.add_argument("--parallele", type=int, default=4, help="imports simultanés")
    args = parser.parse_args()

    load_dotenv()
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SECRET_KEY") or os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        print("SUPABASE_URL et SUPABASE_SECRET_KEY doivent être définis (.env)", file=sys.stderr)
        return 2
    api = Api(url, key)

    files = expand(args.chemins)
    counts: dict[str, int] = {}
    with ThreadPoolExecutor(max_workers=max(1, args.parallele)) as pool:
        for path, (status, message) in zip(files, pool.map(lambda f: import_file(api, f), files)):
            counts[status] = counts.get(status, 0) + 1
            print(f"{path.name} : {status} {message}", file=sys.stderr if status == "erreur" else sys.stdout)
    print(" / ".join(f"{n} {s}" for s, n in sorted(counts.items())))
    return 1 if counts.get("erreur") else 0


if __name__ == "__main__":
    sys.exit(main())
