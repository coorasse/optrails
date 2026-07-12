#!/usr/bin/env python3
"""
Crunch k6 summaries into the only chart that answers the question:
sustained RPS under a p95 latency SLO, per dollar/month, per platform tier.

For each run you pass:
  --result platform=fly tier=shared-1x-1gb scenario=db_read summary=path/to/summary.json

The k6 summary gives overall p95 and achieved RPS for the run. Because the
load script RAMPS arrival rate, a single summary reflects the whole ramp; for a
precise knee, run the script per target RPS (fixed stage) and pass each summary,
or use --slo-ms to accept the run only if its p95 met the SLO.

Outputs a table and, if matplotlib is available, rps_per_dollar.png.
"""
import argparse, json, os, sys

def load_prices(path):
    with open(path) as f:
        data = json.load(f)
    idx = {}
    for t in data["tiers"]:
        idx[(t["platform"], t["tier"])] = t
    return idx

def parse_summary(path):
    with open(path) as f:
        d = json.load(f)
    m = d.get("metrics", {})
    dur = m.get("http_req_duration", {}).get("values", {})
    reqs = m.get("http_reqs", {}).get("values", {})
    p95 = dur.get("p(95)") or dur.get("p95")
    rps = reqs.get("rate")
    ok = m.get("endpoint_ok", {}).get("values", {}).get("rate")
    return {"p95_ms": p95, "rps": rps, "ok_rate": ok}

def kv(pairs):
    out = {}
    for p in pairs:
        k, _, v = p.partition("=")
        out[k] = v
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prices", default=os.path.join(os.path.dirname(__file__), "..", "prices.json"))
    ap.add_argument("--slo-ms", type=float, default=200.0)
    ap.add_argument("--result", action="append", nargs="+", default=[],
                    help="platform=.. tier=.. scenario=.. summary=..")
    ap.add_argument("--png", default=os.path.join(os.path.dirname(__file__), "rps_per_dollar.png"))
    args = ap.parse_args()

    prices = load_prices(args.prices)
    rows = []
    for r in args.result:
        f = kv(r)
        s = parse_summary(f["summary"])
        price = prices.get((f["platform"], f["tier"]))
        usd = price["usd_month"] if price else None
        met_slo = (s["p95_ms"] is not None and s["p95_ms"] <= args.slo_ms)
        rps_eff = s["rps"] if met_slo else 0.0  # only count RPS that held the SLO
        rpsd = (rps_eff / usd) if (usd and rps_eff) else 0.0
        rows.append({
            "platform": f["platform"], "tier": f["tier"],
            "scenario": f.get("scenario", "?"),
            "ram_gb": price["ram_gb"] if price else None,
            "usd_month": usd, "p95_ms": s["p95_ms"], "rps": s["rps"],
            "met_slo": met_slo, "rps_per_usd": rpsd,
        })

    rows.sort(key=lambda x: (x["scenario"], -x["rps_per_usd"]))
    hdr = f'{"platform":9} {"tier":16} {"scenario":11} {"RAM":>5} {"$/mo":>7} {"p95ms":>7} {"RPS":>8} {"SLO":>4} {"RPS/$":>8}'
    print(hdr); print("-" * len(hdr))
    for x in rows:
        print(f'{x["platform"]:9} {x["tier"]:16} {x["scenario"]:11} '
              f'{(x["ram_gb"] or 0):5} {(x["usd_month"] or 0):7} '
              f'{(x["p95_ms"] or 0):7.1f} {(x["rps"] or 0):8.1f} '
              f'{("Y" if x["met_slo"] else "n"):>4} {x["rps_per_usd"]:8.2f}')

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        scen = sorted({x["scenario"] for x in rows})
        fig, ax = plt.subplots(figsize=(10, 0.5 * len(rows) + 2))
        labels = [f'{x["platform"]}/{x["tier"]} [{x["scenario"]}]' for x in rows]
        vals = [x["rps_per_usd"] for x in rows]
        ax.barh(labels, vals)
        ax.set_xlabel(f"Sustained RPS under p95<{args.slo_ms:.0f}ms, per $/month")
        ax.set_title("OptRails: throughput-per-dollar by platform tier")
        ax.invert_yaxis()
        fig.tight_layout()
        fig.savefig(args.png, dpi=130)
        print(f"\nchart -> {args.png}")
    except Exception as e:
        print(f"\n(matplotlib unavailable, skipped chart: {e})")

if __name__ == "__main__":
    main()
