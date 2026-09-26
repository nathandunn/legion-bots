#!/usr/bin/env python3
"""Calibrate Legion Bots by simulation: what a unit class costs, and what a type property is
worth to it.

Two loops, the same shape as tools/calibrate.py in Dodgeball Bots - run headless matches,
parse the `SUMMARY {json}` line, nudge one table of constants, run again.

  costs   Round-robin single-class armies at EQUAL GOLD (count = gold // cost, mirrored across
          sides), plus the unequal-count two-class mixes, fit a Bradley-Terry strength per
          class off the win matrix and move each price by s^k. Target: every class wins about
          half its battles against the field.

  spans   Per class: a specialist type (0.6 in one property, 0.1 in the other four) against an
          Even type of the SAME class, both on that class's natural personality. Two knobs per
          class in UnitClass.SPANS - `curve`, how steeply a starved property falls away, which
          moves the mean; and the five gains, which move the properties against each other.

  swap    Take a mixed army, swap one class's units for equal-gold Brawlers, and see whether
          the win rate moves. A class that is 90/10 in every pairing can still average 50 % by
          construction; this is the check that catches it.

  mixed   Random compositions at equal gold against each other, to see the prices hold outside
          the single-class fights.

Usage:
  tools/calibrate.py costs  [--games 40] [--rounds 3]
  tools/calibrate.py spans  [--games 32] [--rounds 2] [--classes brawler,slinger,shield]
  tools/calibrate.py swap   [--games 40]
  tools/calibrate.py mixed  [--games 30]
  tools/calibrate.py confirm[--games 30]          # fresh round-robin at the costs on disk
  tools/calibrate.py all                          # the lot, in that order

Nothing is written to the scripts unless you pass --write; every run prints the table it
would write so a truncated session still leaves you something to paste.
"""
import argparse, json, math, os, re, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GODOT = os.environ.get("GODOT", "godot")
UNIT_GD = os.path.join(ROOT, "scripts", "unit_class.gd")
STATE = os.path.join(ROOT, "tools", ".calibrate_state.json")

PROPS = ["brawn", "speed", "grit", "reflex", "aim"]
CLASSES = ["brawler", "slinger", "shield"]
LABEL = {"brawler": "Brawler", "slinger": "Slinger", "shield": "Shield"}
# each class fights on the personality a player would actually give it: the cost has to be
# the price of the unit in the role it is bought for, not in a role it is bad at.
PERSONA = {"brawler": "Brawler", "slinger": "Slinger", "shield": "Guardian"}

GOLD = 500          # the real budget: the calibration fights the match the game ships
MAX_SIZE = 20       # MatchManager.MAX_SIZE - never lifted
MIN_COST = 25       # so GOLD // cost never runs past MAX_SIZE and a price stays identifiable
CAP = 60            # seconds of match time. A decisive battle is over in 20-35 s; past that
                    # the two sides are kiting each other, and the cap turns that into an
                    # HP decision (MatchManager.end_match) rather than an afternoon. It is
                    # the single biggest lever on how many battles a session can afford.
WORKERS = int(os.environ.get("CAL_WORKERS", "2"))


# ---------------------------------------------------------------- the constants on disk

def read_costs():
    src = open(UNIT_GD).read()
    out = {}
    for cid in CLASSES:
        m = re.search(r'"%s":\s*\{\s*"label":[^}]*?"cost":\s*(\d+)' % cid, src, re.S)
        out[cid] = int(m.group(1))
    return out


def read_spans():
    src = open(UNIT_GD).read()
    block = re.search(r"const SPANS := \{(.*?)\n\}", src, re.S).group(1)
    out = {}
    for cid in CLASSES:
        row = re.search(r'"%s":\s*\{([^}]*)\}' % cid, block).group(1)
        out[cid] = {k: float(v) for k, v in re.findall(r'"(\w+)":\s*([0-9.]+)', row)}
    return out


def write_costs(costs):
    src = open(UNIT_GD).read()
    for cid, c in costs.items():
        src = re.sub(r'("%s":\s*\{\s*"label":\s*"[^"]*",\s*"cost":\s*)\d+' % cid,
                     lambda m: m.group(1) + str(int(c)), src, count=1)
    open(UNIT_GD, "w").write(src)


def write_spans(spans):
    """Rewrite the SPANS block ONLY. The class TABLE above it has entries keyed by the same
    class names, and a substitution loose enough to find them silently replaced the whole class
    table with span rows - which left every unit a default Mixed robot and the sim still printing
    a SUMMARY, so 480 battles were measured against a game that no longer existed."""
    src = open(UNIT_GD).read()
    m = re.search(r"(const SPANS := \{\n)(.*?)(\n\})", src, re.S)
    if m is None:
        raise RuntimeError("cannot find the SPANS block in %s" % UNIT_GD)
    block = m.group(2)
    for cid, row in spans.items():
        line = '\t"%s":%s {"curve": %.2f, %s},' % (
            cid, " " * (9 - len(cid)), row["curve"],
            ", ".join('"%s": %.2f' % (p, row[p]) for p in PROPS))
        block, n = re.subn(r'\t"%s":\s*\{[^}]*\},' % cid, lambda _m: line, block, count=1)
        if n != 1:
            raise RuntimeError("no SPANS row for %s" % cid)
    src = src[:m.start(2)] + block + src[m.end(2):]
    open(UNIT_GD, "w").write(src)


def costs_arg(costs):
    return ",".join("%s:%d" % (k, v) for k, v in sorted(costs.items()))


def gains_arg(spans):
    bits = []
    for cid, row in sorted(spans.items()):
        for k in ["curve"] + PROPS:
            bits.append("%s.%s:%.4f" % (cid, k, row[k]))
    return ",".join(bits)


# ---------------------------------------------------------------- armies

SPEC_HI = 0.6           # the specialist's one strong property; the other four share the rest


def spec_type_name(p):
    return "Spec" + p.capitalize()


def types_arg():
    """Every specialist type, registered by name for this run only (--types=)."""
    lo = (1.0 - SPEC_HI) / (len(PROPS) - 1)
    out = []
    for p in PROPS:
        vals = "/".join("%.3f" % (SPEC_HI if q == p else lo) for q in PROPS)
        out.append("%s/%s" % (spec_type_name(p), vals))
    return ",".join(out)


def army_spec(entries, type_name="Even", persona=None):
    """entries: [(class_id, count)] -> 'brawler:12:Even:Brawler,...'"""
    parts = []
    for cid, n in entries:
        if n <= 0:
            continue
        parts.append("%s:%d:%s:%s" % (cid, n, type_name, persona or PERSONA[cid]))
    return ",".join(parts)


def single(cid, costs, gold=GOLD):
    """The biggest army of one class that `gold` and the 20-unit cap allow."""
    n = min(MAX_SIZE, gold // costs[cid])
    return [(cid, max(int(n), 1))]


def mix(weights, costs, gold=GOLD):
    """weights: {class: share of the gold}. Buys down to the cap, spends the remainder on the
    cheapest class that still fits."""
    tot = sum(weights.values())
    out = {}
    for cid, w in weights.items():
        out[cid] = max(int((gold * w / tot) // costs[cid]), 0)
    while sum(out.values()) > MAX_SIZE:
        worst = max(out, key=lambda c: (out[c], -costs[c]))
        out[worst] -= 1
    spent = sum(out[c] * costs[c] for c in out)
    for cid in sorted(out, key=lambda c: costs[c]):
        while spent + costs[cid] <= gold and sum(out.values()) < MAX_SIZE:
            out[cid] += 1
            spent += costs[cid]
    return [(c, n) for c, n in out.items() if n > 0]


def army_gold(entries, costs):
    return sum(n * costs[c] for c, n in entries)


def army_name(entries):
    return " + ".join("%d %s" % (n, LABEL[c]) for c, n in entries)


# ---------------------------------------------------------------- running matches

_runs = [0, 0.0]   # batches, seconds


def run(red, blue, games, costs, spans, seed, cap=CAP, type_red=None, type_blue=None):
    args = [GODOT, "--headless", "--path", ROOT, "--",
            "--sim=%d" % games, "--seed=%d" % seed, "--cap=%d" % cap,
            "--red=%s" % red, "--blue=%s" % blue,
            "--costs=" + costs_arg(costs), "--gains=" + gains_arg(spans),
            "--types=" + types_arg()]
    t0 = time.time()
    out = subprocess.run(args, capture_output=True, text=True, timeout=7200).stdout
    _runs[0] += 1
    _runs[1] += time.time() - t0
    # A broken script still prints a SUMMARY: Robot and UnitClass abort the failed call and
    # carry on with default field values, so the batch completes and the numbers are fiction.
    # Never measure that.
    if "SCRIPT ERROR" in out:
        bad = [l for l in out.splitlines() if "SCRIPT ERROR" in l]
        raise RuntimeError("%d SCRIPT ERRORs in a calibration batch - refusing the numbers:\n%s"
                           % (len(bad), "\n".join(bad[:5])))
    for line in out.splitlines():
        if line.startswith("SUMMARY "):
            return json.loads(line[8:])
    raise RuntimeError("no SUMMARY (godot said):\n" + out[-3000:])


def duel(red_entries, blue_entries, games, costs, spans, seed,
         red_type="Even", blue_type="Even", cap=CAP):
    """Half the games with A on Red, half with A on Blue. Draws count half.
    Returns (win rate of A, games, sigma, avg duration)."""
    half = max(games // 2, 1)
    a = army_spec(red_entries, red_type)
    b = army_spec(blue_entries, blue_type)
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        f1 = ex.submit(run, a, b, half, costs, spans, seed, cap)
        f2 = ex.submit(run, b, a, half, costs, spans, seed + 4177, cap)
        x, y = f1.result(), f2.result()
    wins = x["wins"][0] + y["wins"][1]
    draws = x["draws"] + y["draws"]
    n = x["matches"] + y["matches"]
    w = (wins + 0.5 * draws) / n
    dur = (x["avg_duration"] * x["matches"] + y["avg_duration"] * y["matches"]) / n
    return w, n, math.sqrt(max(w * (1 - w), 0.01) / n), dur


# ---------------------------------------------------------------- Bradley-Terry

def bradley_terry(wins, iters=500, prior=0.5):
    """wins[i][j] = games i won against j (draws already split). Returns {class: strength},
    geometric mean pinned to 1. `prior` adds a phantom win each way so a 100-0 pairing does
    not send a strength to infinity."""
    ids = list(wins.keys())
    s = {i: 1.0 for i in ids}
    W = {i: sum(wins[i].values()) + prior * (len(ids) - 1) for i in ids}
    N = {(i, j): wins[i].get(j, 0) + wins[j].get(i, 0) + 2 * prior for i in ids for j in ids if i != j}
    for _ in range(iters):
        new = {}
        for i in ids:
            d = sum(N[(i, j)] / (s[i] + s[j]) for j in ids if j != i)
            new[i] = W[i] / d if d > 0 else s[i]
        gm = math.exp(sum(math.log(max(v, 1e-9)) for v in new.values()) / len(ids))
        s = {i: v / gm for i, v in new.items()}
    return s


# ---------------------------------------------------------------- the cost loop

def cost_round(costs, spans, games, seed, pure=False):
    """Every single-class pairing plus every two-class mix against the odd class out.
    `pure` drops the mixes: half the battles, which is what an intermediate round wants when
    it is only being asked which way to move a price. Returns (win matrix, rows)."""
    pairs = []
    for i in range(len(CLASSES)):
        for j in range(i + 1, len(CLASSES)):
            pairs.append((single(CLASSES[i], costs), single(CLASSES[j], costs), CLASSES[i], CLASSES[j]))
    # unequal-count equal-gold: half the gold in each of two classes, against all of the third
    if not pure:
        for i in range(len(CLASSES)):
            for j in range(i + 1, len(CLASSES)):
                k = [c for c in CLASSES if c not in (CLASSES[i], CLASSES[j])][0]
                m = mix({CLASSES[i]: 0.5, CLASSES[j]: 0.5}, costs)
                pairs.append((m, single(k, costs), "+".join([CLASSES[i], CLASSES[j]]), k))

    rows = []
    for n, (ra, rb, na, nb) in enumerate(pairs):
        w, g, sg, dur = duel(ra, rb, games, costs, spans, seed + n * 131)
        rows.append({"a": na, "b": nb, "a_army": army_name(ra), "b_army": army_name(rb),
                     "a_gold": army_gold(ra, costs), "b_gold": army_gold(rb, costs),
                     "w": w, "n": g, "sigma": sg, "dur": dur})
        print("    %-28s %4dg  vs %-28s %4dg   %5.1f%% +-%4.1f  (n=%d, avg %ds)" % (
            army_name(ra), army_gold(ra, costs), army_name(rb), army_gold(rb, costs),
            w * 100, sg * 100, g, dur), flush=True)

    # the win matrix over CLASSES; a mix contributes half a result to each of its two classes
    wins = {c: {d: 0.0 for d in CLASSES if d != c} for c in CLASSES}
    for r in rows:
        aw = r["w"] * r["n"]
        bw = r["n"] - aw
        a_parts = r["a"].split("+")
        b_parts = r["b"].split("+")
        for ap in a_parts:
            for bp in b_parts:
                if ap == bp:
                    continue
                f = 1.0 / (len(a_parts) * len(b_parts))
                wins[ap][bp] += aw * f
                wins[bp][ap] += bw * f
    return wins, rows


def field_rates(rows):
    """Mean win rate of each class against everything it met, and the sigma of that mean."""
    acc = {c: [0.0, 0.0] for c in CLASSES}   # weighted wins, games
    for r in rows:
        for ap in r["a"].split("+"):
            acc[ap][0] += r["w"] * r["n"] / len(r["a"].split("+"))
            acc[ap][1] += r["n"] / len(r["a"].split("+"))
        for bp in r["b"].split("+"):
            acc[bp][0] += (1 - r["w"]) * r["n"] / len(r["b"].split("+"))
            acc[bp][1] += r["n"] / len(r["b"].split("+"))
    out = {}
    for c in CLASSES:
        w = acc[c][0] / max(acc[c][1], 1)
        out[c] = (w, acc[c][1], math.sqrt(max(w * (1 - w), 0.01) / max(acc[c][1], 1)))
    return out


def rescale(costs):
    """Only ratios matter, so pin the level: the cheapest class costs MIN_COST, which is the
    price at which GOLD buys exactly MAX_SIZE of it and no cheaper."""
    lo = min(costs.values())
    k = MIN_COST / float(lo)
    return {c: max(int(round(costs[c] * k)), MIN_COST) for c in costs}


# How hard to push a price for a given Bradley-Terry strength, and how far a price may move in
# one round. POWER was 0.55 for the first two rounds and it wildly overshot: the win rate turns
# out to be about ten times steeper in price than that assumes, because gold buys *bodies* and
# a melee is closer to Lanchester's square law than to a linear trade. Measured over rounds 1
# and 2: d(logit win rate)/d(ln price) is -16 for the Brawler and -6 for the Shield, so a
# strength of e (2.72) wants a price move of roughly 1.1x, not 1.7x. Hence 0.18.
POWER = 0.18
TRUST = 1.5   # no price may move by more than this in one round, whatever the fit says


def tune_costs(costs, spans, games, rounds, seed, power, write, history, ladder=None, pure=False):
    # Pin the price level before the first probe. Below MIN_COST the 20-unit cap, not the
    # gold, decides the army size, and a price the army never feels cannot be measured.
    costs = rescale(costs)
    print("  starting prices (level pinned so no class is unit-capped): %s" % costs_arg(costs), flush=True)
    for r in range(rounds):
        g = ladder[min(r, len(ladder) - 1)] if ladder else games
        print("  cost round %d - %s (n=%d)" % (r + 1, costs_arg(costs), g), flush=True)
        wins, rows = cost_round(costs, spans, g, seed + r * 977, pure and r < rounds - 1)
        s = bradley_terry(wins)
        fr = field_rates(rows)
        print("    strengths " + ", ".join("%s %.2f" % (LABEL[c], s[c]) for c in CLASSES), flush=True)
        print("    vs field  " + ", ".join("%s %.1f%%+-%.1f" % (LABEL[c], fr[c][0] * 100, fr[c][2] * 100)
                                           for c in CLASSES), flush=True)
        history.append({"costs": dict(costs), "rows": rows, "strength": s, "field": {c: fr[c] for c in fr}})
        # checkpoint every round: a session that runs out of time still leaves fitted prices
        # on disk and a state file to write the report from, not a half-finished nothing.
        save_state("costs", {"final": dict(costs), "history": history})
        if write:
            write_costs(costs)
        worst = max(abs(fr[c][0] - 0.5) for c in CLASSES)
        tol = max(fr[c][2] for c in CLASSES)
        if worst <= tol:
            print("    every class inside one sigma of even - done", flush=True)
            break
        if r == rounds - 1:
            break
        # a 100-0 pairing fits an arbitrarily large strength, so the step is kept inside a
        # trust region: a price moves by at most TRUST in either direction per round.
        nxt = {c: costs[c] * min(TRUST, max(1.0 / TRUST, s[c] ** power)) for c in CLASSES}
        costs = rescale(nxt)
        print("    -> %s" % costs_arg(costs), flush=True)
    if write:
        write_costs(costs)
        print("  wrote costs to scripts/unit_class.gd", flush=True)
    return costs


# ---------------------------------------------------------------- the span loop

GAIN_TRUST = 1.5   # most a single gain may move in one round
CURVE_TRUST = 1.3  # most the curve may move in one round

SPAN_COUNT = 8    # both sides, every class: the span loop is about the type, not the price
SPAN_CAP = 45     # a mirror match (same class, same personality) stalemates far more often
                  # than a cross-class one, so it gets a tighter clock of its own


def span_probe(cid, spans, costs, games, seed):
    """Specialist in each property vs Even, same class, same personality, same count."""
    n = SPAN_COUNT
    out = {}
    for i, p in enumerate(PROPS):
        w, g, sg, dur = duel([(cid, n)], [(cid, n)], games, costs, spans, seed + i * 313,
                             red_type=spec_type_name(p), blue_type="Even", cap=SPAN_CAP)
        out[p] = (w, g, sg, dur)
        print("      %-6s %5.1f%% +-%4.1f  (n=%d, avg %ds)" % (p, w * 100, sg * 100, g, dur), flush=True)
    return out


def span_score(mean, spread):
    """How good a span row is: the mean matters most (a property should be worth half a battle),
    the spread second (they should all be worth the same half)."""
    return abs(mean - 0.5) + 0.5 * spread


def tune_spans(classes, costs, spans, games, rounds, seed, step, write, history):
    for cid in classes:
        print("  spans for %s" % LABEL[cid], flush=True)
        best = None
        for r in range(rounds):
            print("    round %d - curve %.2f, %s" % (
                r + 1, spans[cid]["curve"],
                ", ".join("%s %.2f" % (p, spans[cid][p]) for p in PROPS)), flush=True)
            res = span_probe(cid, spans, costs, games, seed + r * 641)
            mean = sum(res[p][0] for p in PROPS) / len(PROPS)
            spread = max(res[p][0] for p in PROPS) - min(res[p][0] for p in PROPS)
            print("      mean %.1f%%, spread %.1f points" % (mean * 100, spread * 100), flush=True)
            history.append({"class": cid, "spans": dict(spans[cid]), "probe": res,
                            "mean": mean, "spread": spread})
            save_state("spans", {"final": spans, "history": history})
            sc = span_score(mean, spread)
            if best is None or sc < best[0]:
                best = (sc, dict(spans[cid]), res, r + 1)
            if r == rounds - 1:
                break
            # Trust regions. A property 50 points off asks for a 2.7x move under the raw rule,
            # and that overshoots every time: the measured sensitivity is only 0.2-1.0 points of
            # win rate per 1 % of gain, and sigma is 10 points, so most of a big deviation is
            # noise plus a curve change it should not be credited with.
            row = dict(spans[cid])
            cm = min(CURVE_TRUST, max(1.0 / CURVE_TRUST, step ** ((mean - 0.5) / 0.12)))
            row["curve"] = min(2.2, max(0.25, row["curve"] * cm))
            for p in PROPS:
                gm_p = min(GAIN_TRUST, max(1.0 / GAIN_TRUST, step ** (-(res[p][0] - mean) / 0.15)))
                row[p] = min(4.0, max(0.20, row[p] * gm_p))
            gm = math.exp(sum(math.log(row[p]) for p in PROPS) / len(PROPS))
            for p in PROPS:
                row[p] = min(4.0, max(0.20, row[p] / gm))
            spans[cid] = row
            print("      -> curve %.2f, %s" % (row["curve"], ", ".join("%s %.2f" % (p, row[p]) for p in PROPS)), flush=True)
        # Keep the best round, not the last. With sigma near 8 points the tuner will happily
        # walk away from a good table chasing noise, and it did: the Brawler's third round
        # (mean 47 %, spread 15) was better than its fifth.
        if best is not None:
            spans[cid] = best[1]
            print("    keeping round %d - curve %.2f, %s  (mean %.1f%%)" % (
                best[3], best[1]["curve"], ", ".join("%s %.2f" % (p, best[1][p]) for p in PROPS),
                sum(best[2][p][0] for p in PROPS) / len(PROPS) * 100), flush=True)
            history.append({"class": cid, "spans": dict(best[1]), "probe": best[2],
                            "kept_round": best[3]})
            save_state("spans", {"final": spans, "history": history})
        if write:
            write_spans(spans)
    return spans


# ---------------------------------------------------------------- the swap check

def swap_check(costs, spans, games, seed):
    """A mixed army, then the same army with one class swapped for equal gold of another.
    If the class is priced right the win rate should not move more than noise."""
    base = mix({c: 1.0 for c in CLASSES}, costs)
    field = mix({"brawler": 0.4, "slinger": 0.3, "shield": 0.3}, costs)
    print("    reference army   %s (%dg)" % (army_name(base), army_gold(base, costs)), flush=True)
    print("    opposing field   %s (%dg)" % (army_name(field), army_gold(field, costs)), flush=True)
    w0, n0, s0, _ = duel(base, field, games, costs, spans, seed)
    print("    baseline         %5.1f%% +-%4.1f (n=%d)" % (w0 * 100, s0 * 100, n0), flush=True)
    rows = []
    for cid in CLASSES:
        # Brawler cannot be swapped for Brawlers; Slinger is its stand-in substitute
        into = "slinger" if cid == "brawler" else "brawler"
        d = {c: n for c, n in base}
        if d.get(cid, 0) == 0:
            continue
        freed = d[cid] * costs[cid]
        d[cid] = 0
        add = min(freed // costs[into], MAX_SIZE - sum(d.values()))
        d[into] = d.get(into, 0) + int(add)
        # spend the rounding remainder on the cheapest class that is not the one on trial,
        # so the two armies really are worth the same gold and not just nearly
        spent = sum(d[c] * costs[c] for c in d)
        for c in sorted([x for x in CLASSES if x != cid], key=lambda x: costs[x]):
            while spent + costs[c] <= GOLD and sum(d.values()) < MAX_SIZE:
                d[c] = d.get(c, 0) + 1
                spent += costs[c]
        alt = [(c, n) for c, n in d.items() if n > 0]
        w, n, sg, _ = duel(alt, field, games, costs, spans, seed + 7919)
        delta = w - w0
        sig = math.sqrt(s0 ** 2 + sg ** 2)
        rows.append({"class": cid, "into": into, "army": army_name(alt),
                     "gold": army_gold(alt, costs), "unspent": GOLD - army_gold(alt, costs),
                     "w": w, "n": n, "sigma": sg, "base": w0, "base_n": n0, "base_sigma": s0,
                     "delta": delta, "delta_sigma": sig, "within": abs(delta) <= sig})
        print("    %-8s -> %-8s %-34s %5.1f%% +-%4.1f  delta %+5.1f (+-%4.1f) %s" % (
            LABEL[cid], LABEL[into], army_name(alt), w * 100, sg * 100,
            delta * 100, sig * 100, "within noise" if abs(delta) <= sig else "OUTSIDE"), flush=True)
    return {"base": {"army": army_name(base), "gold": army_gold(base, costs), "w": w0,
                     "n": n0, "sigma": s0, "field": army_name(field)}, "swaps": rows}


# ---------------------------------------------------------------- mixed sanity

MIXES = [
    ("Fists first",  {"brawler": 0.7, "slinger": 0.15, "shield": 0.15}),
    ("Stones first", {"brawler": 0.15, "slinger": 0.7, "shield": 0.15}),
    ("Wall first",   {"brawler": 0.15, "slinger": 0.15, "shield": 0.7}),
    ("Even thirds",  {"brawler": 1.0, "slinger": 1.0, "shield": 1.0}),
]


def mixed_pass(costs, spans, games, seed):
    armies = [(nm, mix(w, costs)) for nm, w in MIXES]
    rows = []
    for i in range(len(armies)):
        for j in range(i + 1, len(armies)):
            (na, a), (nb, b) = armies[i], armies[j]
            w, n, sg, dur = duel(a, b, games, costs, spans, seed + (i * 7 + j) * 97)
            rows.append({"a": na, "b": nb, "a_army": army_name(a), "b_army": army_name(b),
                         "a_gold": army_gold(a, costs), "b_gold": army_gold(b, costs),
                         "w": w, "n": n, "sigma": sg, "dur": dur})
            print("    %-12s %-30s vs %-12s %-30s %5.1f%% +-%4.1f" % (
                na, army_name(a), nb, army_name(b), w * 100, sg * 100), flush=True)
    return rows


# ---------------------------------------------------------------- main

def save_state(key, value):
    st = {}
    if os.path.exists(STATE):
        st = json.load(open(STATE))
    st[key] = value
    st["_when"] = time.strftime("%Y-%m-%d %H:%M:%S")
    json.dump(st, open(STATE, "w"), indent=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["costs", "spans", "swap", "mixed", "confirm", "all"])
    ap.add_argument("--cap", type=int, default=0, help="override the match clock for this run")
    ap.add_argument("--games", type=int, default=40)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--seed", type=int, default=1000)
    ap.add_argument("--power", type=float, default=POWER, help="cost_new = cost * strength^power")
    ap.add_argument("--step", type=float, default=1.35, help="span nudge per round")
    ap.add_argument("--classes", default=",".join(CLASSES))
    ap.add_argument("--ladder", default="", help="games per cost round, e.g. 12,20,40")
    ap.add_argument("--pure", action="store_true", help="skip the two-class mixes except in the last round")
    ap.add_argument("--write", action="store_true")
    a = ap.parse_args()

    if a.cap:
        globals()["CAP"] = a.cap
    costs, spans = read_costs(), read_spans()
    print("costs on disk: %s" % costs_arg(costs))
    for c in CLASSES:
        print("spans  %-8s curve %.2f  %s" % (LABEL[c], spans[c]["curve"],
              ", ".join("%s %.2f" % (p, spans[c][p]) for p in PROPS)))
    t0 = time.time()

    if a.mode in ("costs", "all"):
        print("\n== class costs ==", flush=True)
        hist = []
        lad = [int(x) for x in a.ladder.split(",") if x.strip()] or None
        costs = tune_costs(costs, spans, a.games, len(lad) if lad else a.rounds,
                           a.seed, a.power, a.write, hist, lad, a.pure)
        save_state("costs", {"final": costs, "history": hist})
        print("  final costs: %s" % costs_arg(costs), flush=True)

    if a.mode in ("spans", "all"):
        print("\n== type spans, per class ==", flush=True)
        hist = []
        # a span probe is a mirror match, so it carries no matchup signal at all - only noise -
        # and 24 is the fewest battles that gets the sigma under about 10 points.
        spans = tune_spans([c for c in a.classes.split(",") if c in CLASSES],
                           costs, spans, max(a.games, 24), a.rounds, a.seed + 50, a.step, a.write, hist)
        save_state("spans", {"final": spans, "history": hist})

    if a.mode in ("swap", "all"):
        print("\n== swap check ==", flush=True)
        res = swap_check(costs, spans, a.games, a.seed + 200)
        save_state("swap", res)

    if a.mode in ("mixed", "all"):
        print("\n== mixed armies ==", flush=True)
        rows = mixed_pass(costs, spans, max(a.games * 3 // 4, 20), a.seed + 300)
        save_state("mixed", rows)

    if a.mode in ("confirm", "all"):
        print("\n== confirmation round-robin at the final costs ==", flush=True)
        wins, rows = cost_round(costs, spans, a.games, a.seed + 8000, a.pure)
        fr = field_rates(rows)
        for c in CLASSES:
            print("    %-8s vs field %5.1f%% +-%4.1f over %d games" % (
                LABEL[c], fr[c][0] * 100, fr[c][2] * 100, fr[c][1]), flush=True)
        save_state("confirm", {"costs": costs, "rows": rows,
                               "field": {c: fr[c] for c in fr}})

    print("\n%d batches, %ds of godot, %ds wall" % (_runs[0], _runs[1], time.time() - t0))
    print("costs: %s" % costs_arg(costs))
    for c in CLASSES:
        print("spans  %-8s curve %.2f  %s" % (LABEL[c], spans[c]["curve"],
              ", ".join("%s %.2f" % (p, spans[c][p]) for p in PROPS)))
    print("state: %s" % STATE)


if __name__ == "__main__":
    main()
