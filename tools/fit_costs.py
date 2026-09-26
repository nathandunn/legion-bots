#!/usr/bin/env python3
"""Solve for the price list from the count-response curves measured by calibrate.py.

Bradley-Terry fits a single strength per class, which is exactly the wrong shape for what the
three classes turned out to be: Slinger beats Brawler, Brawler beats Shield, Shield annihilates
Slinger. A cycle has no consistent strength ordering, so BT oscillates (it did: Shield went
25 -> 81 -> 25 over two rounds). What does fit is one curve *per pairing*: the logit of A's win
rate is close to linear in ln(count ratio), and at equal gold the count ratio IS the inverse
price ratio. Three curves, three prices, one free level - solve for the triple whose three
mean-against-the-field numbers are all as near 50 % as integer prices allow.

Edit MEASURED below with (count_a, count_b, a_win_rate, n) rows from the calibrate.py logs.
"""
import math, sys

CLASSES = ["brawler", "slinger", "shield"]
GOLD, MAX_SIZE = 500, 20

# every single-class pairing measured across all rounds, at whatever prices produced the counts
MEASURED = {
    ("brawler", "slinger"): [(15, 20, 0.594, 16), (14, 20, 0.3205, 78), (13, 20, 0.125, 24)],
    ("brawler", "shield"):  [(15, 20, 0.0625, 16), (14, 17, 0.458, 24), (14, 14, 0.900, 30),
                             (14, 11, 1.0, 24)],
    ("slinger", "shield"):  [(20, 17, 0.0, 24), (20, 14, 0.267, 30), (20, 11, 0.917, 24)],
}


def logit(p, n):
    p = min(max(p, 0.5 / n), 1 - 0.5 / n)   # a clean sweep is not infinite evidence
    return math.log(p / (1 - p))


def fit():
    out = {}
    for k, pts in MEASURED.items():
        xs = [math.log(a / b) for a, b, _, _ in pts]
        ys = [logit(p, n) for _, _, p, n in pts]
        mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
        sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
        sxx = sum((x - mx) ** 2 for x in xs)
        a = sxy / sxx
        out[k] = (a, mx - my / a)
    return out


def predict(costs, curves):
    n = {c: min(MAX_SIZE, GOLD // costs[c]) for c in CLASSES}
    pair = {}
    for (i, j), (a, x0) in curves.items():
        pair[(i, j)] = 1.0 / (1.0 + math.exp(-a * (math.log(n[i] / n[j]) - x0)))
    field = {}
    for c in CLASSES:
        ws = [w if i == c else 1 - w for (i, j), w in pair.items() if c in (i, j)]
        field[c] = sum(ws) / len(ws)
    return n, pair, field


def main():
    curves = fit()
    for (i, j), (a, x0) in curves.items():
        print("%-8s vs %-8s: slope %5.2f per ln(count ratio), even at price ratio %.3f"
              % (i, j, a, math.exp(x0)))
    floor = int(sys.argv[1]) if len(sys.argv) > 1 else 12   # smallest army we trust the fit for
    best = []
    for b in range(GOLD // MAX_SIZE, 46):
        for s in range(GOLD // MAX_SIZE, 46):
            for h in range(GOLD // MAX_SIZE, 46):
                cs = {"brawler": b, "slinger": s, "shield": h}
                n, pair, f = predict(cs, curves)
                if min(n.values()) < floor:
                    continue
                best.append((max(abs(v - 0.5) for v in f.values()), cs, n, pair, f))
    best.sort(key=lambda r: r[0])
    print("\nbest price lists with every army at least %d units:" % floor)
    seen = set()
    for score, cs, n, pair, f in best:
        key = tuple(n[c] for c in CLASSES)
        if key in seen:
            continue
        seen.add(key)
        print("  %-34s units %-14s field %-34s worst %.1f pts" % (
            ", ".join("%s %d" % (c[:2], cs[c]) for c in CLASSES),
            ", ".join(str(n[c]) for c in CLASSES),
            ", ".join("%s %.0f%%" % (c[:2], f[c] * 100) for c in CLASSES), score * 100))
        if len(seen) >= 8:
            break


if __name__ == "__main__":
    main()
