"""Génère des exports de cycles de perçage synthétiques, au format exact des vrais.

    python scripts/generer_synthetiques.py [--cycles 600] [--graine 42] [--sortie donnees/synthetiques/]

Les fichiers produits s'importent comme les vrais (onglet Dépôt de l'app web ou
scripts/charger_cycles.py) et remplissent donc toutes les tables de la même
façon. Ils portent le champ « Synthetic = True » : en base, cycle.is_synthetic
vaut true et select public.purge_synthetic() les supprime tous.

Le monde simulé, calibré sur un export réel :
  * 3 boîtiers, 1 moteur chacun, 6 têtes (2 par boîtier), sur `--jours` jours ouvrés ;
  * 3 programmes (empilements de matériaux) : Ti/Al/Ti en 3 étapes (celui du fichier
    réel), CFRP/Al en 2 étapes, Al en 1 étape ; le Pset 0 passe de la version 9 à 10
    en cours de période (avance de l'étape 3 modifiée), le boîtier 2 change de firmware ;
  * usure d'outil : le couple et la poussée montent avec le nombre de trous depuis
    le dernier changement d'outil (Head Local Counter 1), l'outil est changé en fin de vie ;
  * anomalies : casse d'outil (cycle interrompu, stop code 4), bourrage de copeaux
    (couple qui dérive et oscille), épaisseur de couche hors tolérance.

verite_terrain.csv donne, pour chaque fichier, ce qu'aucun export réel ne contient :
usure réelle de l'outil, anomalie injectée, épaisseurs des couches. C'est la cible
pour entraîner et évaluer les modèles, à ne jamais utiliser comme variable d'entrée.
"""

import argparse
import csv
import math
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np

RATE = 100  # Hz
TORQUE_LSB = 0.048828  # résolution du courant de broche observée (100/2048 A)
THRUST_LSB = 0.011719  # résolution du courant d'avance observée
POS_LSB = 0.00385      # résolution de position observée (mm)

# couple (A) et poussée (A) de référence d'un outil neuf, à l'avance de référence (mm/tr)
MATERIALS = {
    "Ti":   {"torque": 9.4, "thrust": 0.52, "feed_ref": 0.04},
    "Al":   {"torque": 3.0, "thrust": 0.12, "feed_ref": 0.10},
    "CFRP": {"torque": 3.8, "thrust": 0.30, "feed_ref": 0.08},
}


@dataclass
class Step:
    material: str
    thickness: float     # épaisseur nominale de la couche (mm)
    tail: float          # course après la sortie de couche, avant détection (mm)
    rpm: float
    feed_mm_tr: float
    torque_min: float    # seuil de détection de sortie de matière (0 = fin sur course)
    torque_max: float = 0.0
    gap: float = 0.0
    lub_air: float = 7.0
    lub_flow: float = 15.0

    @property
    def feed_mm_s(self):
        return self.rpm * self.feed_mm_tr / 60

    @property
    def stop_code(self):
        return 2048 if self.torque_min > 0 else 1


@dataclass
class Program:
    pset_nb: int
    version: int
    steps: list
    retract_rpm: float = 516
    retract_feed: float = 13.0


def programs_at(day: int, total_days: int) -> dict:
    """Programmes en vigueur ; le Pset 0 change de version aux 55 % de la période."""
    p0_v10 = day >= int(total_days * 0.55)
    return {
        0: Program(0, 10 if p0_v10 else 9, [
            Step("Ti", 9.0, 6.0, 516, 0.04, 5.5, gap=6.0),
            Step("Al", 4.3, 0.0, 1600, 0.10, 0.0, torque_max=7.5),
            Step("Ti", 7.5, 4.7, 516, 0.035 if p0_v10 else 0.03, 1.0, gap=3.0),
        ]),
        1: Program(1, 3, [
            Step("CFRP", 8.0, 2.0, 1600, 0.08, 1.5),
            Step("Al", 6.0, 1.0, 2400, 0.10, 0.8),
        ], retract_rpm=1600),
        2: Program(2, 5, [Step("Al", 20.0, 1.5, 2400, 0.12, 0.8)], retract_rpm=2400),
    }


@dataclass
class Box:
    sn: str
    name: str
    firmware: str
    firmware_update_day: int | None
    operation_time: float
    motor_sn: str
    motor_operation_time: float
    next_cycle_id: int


@dataclass
class Head:
    tag_uid: str
    name: str
    box: int
    pset: int
    bias: float
    global_counter: int
    local_1: int = 0
    local_2: int = 0
    tool_id: int = 0
    tool_life: int = 200
    tool_changes: int = 0
    history: list = field(default_factory=list)


# ---------------------------------------------------------------- simulation d'un cycle

def smoothstep(x):
    x = np.clip(x, 0, 1)
    return x * x * (3 - 2 * x)


def red_noise(rng, n, sigma, phi=0.995):
    """Dérive lente (bruit AR(1)) de variance stationnaire sigma²."""
    e = rng.normal(0, sigma * math.sqrt(1 - phi * phi), n)
    out = np.empty(n)
    acc = rng.normal(0, sigma)
    for i in range(n):
        acc = phi * acc + e[i]
        out[i] = acc
    return out


def quantize(x, lsb):
    return np.round(x / lsb) * lsb


def simulate(rng, program: Program, wear: float, head_bias: float, anomaly: str):
    """Renvoie (colonnes de mesures, résultats d'étapes, infos de vérité terrain)."""
    cols = {k: [] for k in ("pos", "tq", "th", "tq0", "th0", "step", "stop", "mem", "pw", "gap")}
    results, truth = [], {"thicknesses": []}
    depth = 0.517 + rng.normal(0, 0.05)  # la mesure démarre juste avant le contact
    wear_tq = 1 + 0.55 * wear ** 1.6
    wear_th = 1 + 0.9 * wear ** 1.3
    n_steps = len(program.steps)

    anomaly_step = None
    if anomaly == "casse_outil":
        candidates = [i for i, s in enumerate(program.steps) if s.material != "Al"] or [0]
        anomaly_step = int(rng.choice(candidates))
    elif anomaly == "bourrage_copeaux":
        anomaly_step = int(np.argmax([s.thickness for s in program.steps]))
    elif anomaly == "epaisseur_hors_tolerance":
        anomaly_step = int(rng.integers(n_steps))
    truth["anomaly_step"] = None if anomaly_step is None else anomaly_step + 1

    for idx, step in enumerate(program.steps):
        mat = MATERIALS[step.material]
        thickness = step.thickness + rng.normal(0, 0.08)
        if anomaly == "epaisseur_hors_tolerance" and idx == anomaly_step:
            thickness += rng.choice([-1, 1]) * rng.uniform(0.9, 1.6)
        truth["thicknesses"].append(round(thickness, 3))
        tail = step.tail * rng.uniform(0.85, 1.15)
        travel = thickness + tail
        dz = step.feed_mm_s / RATE
        n = max(3, int(math.ceil(travel / dz)))
        d = np.arange(n) * dz  # profondeur dans l'étape

        feed_factor = (step.feed_mm_tr / mat["feed_ref"]) ** 0.75
        plateau = mat["torque"] * feed_factor * wear_tq * head_bias
        plateau_th = mat["thrust"] * feed_factor * wear_th * head_bias

        engage = smoothstep(d / 1.2)
        exit_ = 1 - smoothstep((d - thickness) / 0.8)
        drift = 1 + red_noise(rng, n, 0.06)
        heating = 1 + 0.22 * np.clip(d / thickness, 0, 1)  # le couple monte au fil de la couche
        tq = plateau * engage * exit_ * drift * heating
        th = plateau_th * engage * exit_ * (1 + red_noise(rng, n, 0.08))
        # après la sortie de couche : couple résiduel qui décroît jusqu'à la détection
        after = d > thickness
        tq += np.where(after, plateau * 0.28 * np.exp(-(d - thickness) / max(tail / 1.5, 0.3)), 0)
        th += np.where(after, 0.05, 0)
        # fin sur course : on entame déjà la couche suivante
        if step.torque_min == 0 and idx + 1 < n_steps:
            nxt = MATERIALS[program.steps[idx + 1].material]
            ramp = smoothstep((d - (travel - 0.35)) / 0.35)
            tq += ramp * nxt["torque"] * 0.7 * wear_tq
            th += ramp * nxt["thrust"] * 0.7 * wear_th

        stop_code = step.stop_code
        if anomaly == "bourrage_copeaux" and idx == anomaly_step:
            prog = np.clip(d / travel, 0, 1)
            tq *= 1 + 0.45 * prog ** 2 + 0.12 * prog * np.sin(2 * math.pi * 1.4 * np.arange(n) / RATE)
            th *= 1 + 0.3 * prog ** 2
        broke = False
        if anomaly == "casse_outil" and idx == anomaly_step:
            k = int(n * rng.uniform(0.25, 0.7))
            spike = min(n, k + 12)
            tq[k:spike] *= np.linspace(1.3, 1.7, spike - k)
            tq[spike:] = 0.25
            th[spike:] = 0.03
            stop_at = min(n, spike + int(1.5 * RATE))
            n, d, tq, th = stop_at, d[:stop_at], tq[:stop_at], th[:stop_at]
            stop_code, broke = 4, True

        tq = quantize(tq + rng.normal(0, 0.06, n), TORQUE_LSB)
        th = quantize(th + rng.normal(0, 0.012, n), THRUST_LSB)

        # dernier arrêt : la mesure continue quelques secondes, broche arrêtée
        last = idx == n_steps - 1 or broke
        dwell = int(rng.uniform(1.0, 3.0) * RATE) if last else 0
        pos = -(depth + d)
        if dwell:
            pos = np.concatenate([pos, np.full(dwell, pos[-1])])
            tq = np.concatenate([tq, quantize(rng.normal(-0.37, 0.03, dwell), TORQUE_LSB)])
            th = np.concatenate([th, quantize(rng.normal(0.01, 0.01, dwell), THRUST_LSB)])
        total = len(pos)
        pos = quantize(pos, POS_LSB)

        tq0 = round(3.9 + 0.00105 * step.rpm + rng.normal(0, 0.15), 3)
        th0 = round(0.08 + 0.00009 * step.rpm + rng.normal(0, 0.01), 3)
        stop = np.zeros(total)
        stop[-(dwell or int(rng.integers(1, 5))):] = stop_code
        mem = (np.floor(np.minimum(4, 5 * np.arange(total) / total)) if step.torque_min > 0
               else np.zeros(total))
        gap = np.zeros(total)
        if step.gap > 0 and rng.random() < 0.3:
            gap[: int(rng.integers(5, 40))] = round(rng.uniform(0.004, 0.03), 3)
        power = np.round(0.0225 * step.rpm * (tq + tq0) + rng.normal(0, 1.2, total))

        for key, values in (("pos", pos), ("tq", tq), ("th", th), ("tq0", np.full(total, tq0)),
                            ("th0", np.full(total, th0)), ("step", np.full(total, idx + 1)),
                            ("stop", stop), ("mem", mem), ("pw", power), ("gap", gap)):
            cols[key].append(values)

        results.append({
            "step": idx + 1, "stop": stop_code,
            "duration": total / RATE + rng.uniform(0.8, 2.5),
            "m2": abs(pos[-1] - pos[0]), "m1max": tq.max() + abs(rng.normal(0, 0.05)),
            "m2max": th.max(), "m1nl": tq0, "m2nl": th0, "gap": gap.max(),
        })
        depth += d[-1] if len(d) else 0
        if broke:
            break

    cols = {k: np.concatenate(v) for k, v in cols.items()}
    truth["broken"] = any(r["stop"] == 4 for r in results)
    return cols, results, truth


# ---------------------------------------------------------------- écriture au format d'export

def f3(x):
    return f"{x:.3f}".replace(".", ",")


def row(values, width):
    return "\t".join(values + [""] * (width - len(values)))


def write_export(path: Path, ctx: dict, program: Program, cols: dict, results: list):
    b, h = ctx["box"], ctx["head"]
    ok = not any(r["stop"] == 4 for r in results)
    cycle_time = sum(r["duration"] for r in results) + ctx["retract_s"]
    lines = [
        row(["*** General Infos ***"], 13),
        row(["Version", "Date", "Sample Rate (Hz)", "Drilling Cycle ID",
             "Decimal Separator separator", "Synthetic"], 13),
        row(["8", ctx["started_at"].strftime("%Y-%m-%d:%H:%M:%S"), str(RATE),
             str(ctx["cycle_id"]), "Comma", "True"], 13),
        row([], 13),
        row(["*** Control Box Datas ***"], 13),
        "\t".join(["BOX Name", "BOX Type", "BOX SN", "BOX STSE", "BOX Customer Info", "BOX Release",
                   "BOX Firmware Version", "BOX Production Date", "BOX Maintenance Date",
                   "BOX Operation Time", "BOX Power Supply Limit", "BOX Lub Pump Coef.",
                   "Pset Default Selection"]),
        "\t".join([b.name, "CB V2 - Standard", b.sn, "", "", "0", ctx["firmware"], "01/03/2025",
                   ctx["maintenance"], str(int(b.operation_time)), "3000", " 1,000", "FALSE"]),
        row([], 13),
        row(["*** Motor Datas ***"], 13),
        row(["Motor Name", "Motor Type", "Motor STSE", "Motor SN", "Motor Operation Time",
             "Motor M2 Ratio", "Motor M1 CW Ratio", "Motor M1 CCW Ratio", "Motor Winch Limit"], 13),
        row(["M_EDU", "M_EDU", "5000", b.motor_sn, str(int(b.motor_operation_time)), " 21,923",
             " 0,792", " 2,638", "2400"], 13),
        row([], 13),
        row(["*** Head Datas ***"], 13),
        row(["Head Name", "Head Type", "Head TAG UID", "Head Global Counter", "Head Local Counter 1",
             "Head Local Counter 2", "Head M1 Ratio", "Head M2 Ratio", "Customer Info"], 13),
        row([h.name, "Concentric Collet", h.tag_uid, str(h.global_counter), str(h.local_1),
             str(h.local_2), " 5,000", " 1,000"], 13),
        row([], 9),
        row(["*** Pset ***"], 9),
        row(["Pset Type", "Pset Nb.", "Version"], 9),
        row(["Standard", str(program.pset_nb), str(program.version)], 9),
        row([], 9),
        row(["*** Cycle Parameters ***"], 9),
        "\t".join(["Max cycles Limit 1", "Max cycles Limit 2", "CC Pressure", "Max Stroke (mm)",
                   "Vacuum Delay (ms)", "Vacuum Flow min (m/s)", "Retract Rotation Speed (rpm)",
                   "Retract Feed (m/s)", "Disable Abort"]),
        "\t".join(["2000", "0", "9", f3(0), "0", f3(0), str(int(program.retract_rpm)),
                   f3(program.retract_feed), "0"]),
        row([], 9),
        row(["Comment"], 9),
        row([], 9),
        "\t".join(["Cutting tool breakage On/Off", "Cutting tool breakage DEP (mm)",
                   "Cutting tool breakage Thrust (A)", "Cutting tool breakage Torque (A)"]),
        "\t".join([f3(0)] * 4),
        "\t".join(["Lub Preload Time (s)", "Lub Preload Lub Air", "Lub Preload Lub Flow",
                   "Lub Preload Timeout (s)"]),
        "\t".join([f3(0), f3(5), f3(30), f3(0)]),
        row([], 22),
        row(["*** Program ***"], 22),
        "\t".join(["Step Nb", "Step On/Off", "Stroke (mm)", "RPM", "Feed (mm/s)", "Feed (mm/tr)",
                   "Thrust Max (A)", "Torque Max (A)", "Thrust Min (A)", "Torque Min (A)",
                   "Thrust Safety (A)", "Torque Safety (A)", "Gap (mm)", "Peck (nb)", "Delay (ms)",
                   "Stroke Limit (A)", "Thrust Limit (A)", "Torque Limit (A)", "LUB AIR", "LUB FLOW",
                   "Vacuum", "Material"]),
        "\t".join([f3(0)] * 5 + ["Inf"] + [f3(0)] * 16),
    ]
    for i, s in enumerate(program.steps, start=1):
        lines.append("\t".join([f3(i), f3(1), f3(200), f3(s.rpm), f3(s.feed_mm_s), f3(s.feed_mm_tr),
                                f3(0), f3(s.torque_max), f3(0), f3(s.torque_min), f3(0), f3(0),
                                f3(s.gap), f3(0), f3(0), f3(0), f3(0), f3(0), f3(s.lub_air),
                                f3(s.lub_flow), f3(0), f3(0)]))
    lines += [
        row([], 10),
        row(["*** Results ***"], 10),
        row(["Cycle Time (s)", "Distance (mm)", "Cycle OK"], 10),
        row([f"{cycle_time:.6f}".replace(".", ","), f3(abs(cols["pos"][-1])), "True" if ok else "False"], 10),
        row([], 10),
        row(["*** Step Results ***"], 10),
        "\t".join(["Step Number", "Stop Code", "Duration (s)", "Distance M1", "Distance M2", "M1 Max Amp",
                   "M2 Max Amp", "M1 No Load Amp", "M2 No Load Amp", "Gap Max (mm)"]),
    ]
    for r in results:
        lines.append("\t".join([f3(r["step"]), f3(r["stop"]), f3(r["duration"]), f3(0), f3(r["m2"]),
                                f3(r["m1max"]), f3(r["m2max"]), f3(r["m1nl"]), f3(r["m2nl"]), f3(r["gap"])]))
    lines += [
        row([], 11),
        row(["*** Datas ***"], 11),
        "\t".join(["Position (mm)", "I Torque (A)", "I Thrust (A)", "I Torque Empty (A)",
                   "I Thrust Empty (A)", "Step (nb)", "Stop code", "Mem Torque min (A)",
                   "Mem Thrust min (A)", "Torque Power (W)", "Gap Length (mm)"]),
    ]
    data = np.column_stack([cols["pos"], cols["tq"], cols["th"], cols["tq0"], cols["th0"], cols["step"],
                            cols["stop"], cols["mem"], np.zeros(len(cols["pos"])), cols["pw"], cols["gap"]])
    body = "\n".join("\t".join(f"{v:.3f}" for v in r) for r in data).replace(".", ",")
    path.write_text("\n".join(lines) + "\n" + body + "\n", encoding="utf-8")
    return ok, cycle_time


# ---------------------------------------------------------------- parc et planning

def build_fleet(rng, total_days):
    boxes = []
    for i in range(3):
        boxes.append(Box(
            sn=f"SYN{rng.integers(0, 16**5):05X}",
            name=f"NI-sbRIO-9607-SYN{i + 1:02d}",
            firmware="V 3.3.0" if i == 2 else "V 3.2.0",
            firmware_update_day=int(total_days * 0.5) if i == 1 else None,
            operation_time=float(rng.integers(20_000, 60_000)),
            motor_sn=f"SYN-M{i + 1:03d}",
            motor_operation_time=float(rng.integers(30_000, 70_000)),
            next_cycle_id=int(rng.integers(1_500_000_000, 2_000_000_000)),
        ))
    heads = []
    # deux têtes par boîtier ; chaque tête est dédiée à un empilement
    for k, (box, pset) in enumerate([(0, 0), (0, 0), (1, 1), (1, 0), (2, 2), (2, 1)]):
        heads.append(Head(
            tag_uid=f"E0040100{rng.integers(0, 16**8):08X}",
            name=f"SYN{k + 1:02d}DDVTICFT",
            box=box, pset=pset, bias=float(rng.normal(1, 0.04)),
            global_counter=int(rng.integers(200, 2000)),
            local_1=int(rng.integers(0, 120)), local_2=int(rng.integers(0, 300)),
            tool_id=k * 1000, tool_life=int(rng.integers(140, 260)),
        ))
    return boxes, heads


def schedule(rng, n_cycles, start: datetime, total_days):
    """Horaires de cycle répartis sur les jours ouvrés, en deux équipes (6 h - 22 h)."""
    days = [start + timedelta(days=i) for i in range(total_days * 7 // 5 + 7)]
    days = [d for d in days if d.weekday() < 5][:total_days]
    times = []
    for _ in range(n_cycles):
        day = days[int(rng.integers(len(days)))]
        times.append(day + timedelta(seconds=float(rng.uniform(6 * 3600, 22 * 3600))))
    return sorted(times), days


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--cycles", type=int, default=600)
    ap.add_argument("--graine", type=int, default=42)
    ap.add_argument("--jours", type=int, default=120, help="jours ouvrés simulés")
    ap.add_argument("--debut", default="2026-01-05")
    ap.add_argument("--sortie", default=str(Path(__file__).resolve().parent.parent / "donnees" / "synthetiques"))
    args = ap.parse_args()

    rng = np.random.default_rng(args.graine)
    out = Path(args.sortie)
    out.mkdir(parents=True, exist_ok=True)
    boxes, heads = build_fleet(rng, args.jours)
    times, days = schedule(rng, args.cycles, datetime.fromisoformat(args.debut), args.jours)
    day_index = {d.date(): i for i, d in enumerate(days)}
    head_weights = np.array([1.2, 1.0, 1.0, 0.8, 1.1, 0.9])
    head_weights /= head_weights.sum()

    truth_rows, total_samples = [], 0
    for n, started_at in enumerate(times, start=1):
        h = heads[int(rng.choice(len(heads), p=head_weights))]
        b = boxes[h.box]
        day = day_index[started_at.date()]
        progs = programs_at(day, args.jours)
        pset = h.pset if rng.random() > 0.08 else int(rng.integers(3))  # quelques cycles hors série
        program = progs[pset]

        wear = min(h.local_1 / h.tool_life, 1.2)
        p_break = 0.006 + (0.08 if wear > 0.85 else 0)  # outil en fin de vie : casse plus probable
        u = rng.random()
        anomaly = ("casse_outil" if u < p_break else
                   "bourrage_copeaux" if u < p_break + 0.025 else
                   "epaisseur_hors_tolerance" if u < p_break + 0.04 else "aucune")

        cols, results, truth = simulate(rng, program, wear, h.bias, anomaly)
        firmware = ("V 3.3.0" if b.firmware_update_day is not None and day >= b.firmware_update_day
                    else b.firmware)
        ctx = {
            "box": b, "head": h, "started_at": started_at, "cycle_id": b.next_cycle_id,
            "firmware": firmware, "maintenance": "15/12/2025",
            "retract_s": abs(cols["pos"][-1]) / program.retract_feed + rng.uniform(3, 5),
        }
        name = f"{h.tag_uid}_{h.name}_ST_{h.global_counter}_{h.local_1}.xls"
        ok, cycle_time = write_export(out / name, ctx, program, cols, results)
        total_samples += len(cols["pos"])

        truth_rows.append({
            "source_file": name, "box_sn": b.sn, "head_tag_uid": h.tag_uid,
            "drilling_cycle_id": b.next_cycle_id, "started_at": started_at.isoformat(timespec="seconds"),
            "pset_nb": program.pset_nb, "pset_version": program.version,
            "tool_id": h.tool_id, "tool_life_holes": h.tool_life, "tool_holes": h.local_1,
            "tool_wear": round(wear, 4), "anomaly": anomaly, "anomaly_step": truth["anomaly_step"] or "",
            "layer_thicknesses_mm": "|".join(str(t) for t in truth["thicknesses"]), "cycle_ok": ok,
        })

        # compteurs après le cycle
        b.next_cycle_id += int(rng.integers(1, 4))
        b.operation_time += cycle_time / 60
        b.motor_operation_time += cycle_time / 60
        h.global_counter += 1
        h.local_1 += 1
        h.local_2 += 1
        if truth["broken"] or h.local_1 >= h.tool_life:  # changement d'outil
            h.tool_id += 1
            h.local_1 = 0
            h.tool_life = int(rng.integers(140, 260))
            h.tool_changes += 1
            if h.tool_changes % 2 == 0:
                h.local_2 = 0
        if n % 50 == 0:
            print(f"{n}/{args.cycles} cycles générés")

    with open(out / "verite_terrain.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(truth_rows[0]))
        w.writeheader()
        w.writerows(truth_rows)

    counts = {}
    for r in truth_rows:
        counts[r["anomaly"]] = counts.get(r["anomaly"], 0) + 1
    print(f"{args.cycles} fichiers dans {out} ({total_samples:,} mesures).".replace(",", " "))
    print("anomalies :", ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))


if __name__ == "__main__":
    main()
