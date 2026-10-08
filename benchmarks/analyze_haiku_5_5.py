#!/usr/bin/env python3
"""Summarize the Claude Haiku 5.5 runs: classification (one-call modes and ratings) and StreamDecisionBench.

Reads the raw runs from the jev-llm-protocol harness (RESULTS_DIR and SDB_DIR) and writes
data/haiku-5-5.json. Costs use OpenRouter's list prices per million tokens.
"""

import json
import os
import statistics
import subprocess
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).parent
HARNESS = Path(os.environ.get("HARNESS", HERE.parent.parent / "jev-llm-protocol"))
CLASSIFICATION = [HARNESS / "results" / "haiku-5-5", HARNESS / "results" / "haiku-5-5-reasoning-low"]
PRICES = {"anthropic/claude-haiku-5.5": (0.10, 0.50), "anthropic/claude-haiku-4.5": (1.00, 5.00)}


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, round(fraction * (len(ordered) - 1)))]


def score(model, rows):
    arm = "single_request"
    usable = [r for r in rows if "answers" in r[arm]]
    news = [r for r in usable if r["group"] != "sst2"]
    sst = [r for r in usable if r["group"] == "sst2"]
    topic = lambda r: r[arm]["answers"]["topic"]
    input_price, output_price = PRICES[model]
    costs = [(r[arm]["tokens"].get("input_tokens") or 0) * input_price / 1e6 +
             ((r[arm]["tokens"].get("output_tokens") or 0) + (r[arm]["tokens"].get("thinking_tokens") or 0)) * output_price / 1e6
             for r in usable]
    times = [r[arm]["ms"] for r in usable]
    return {
        "ag_news": sum(topic(r)["choice"] == r["expected"] for r in news),
        "sst2": sum(r[arm]["answers"]["sentiment"]["choice"] == r["expected"] for r in sst),
        "brier": statistics.mean(sum((p - (k == r["expected"])) ** 2 for k, p in topic(r)["probabilities"].items())
                                 for r in news) if news else None,
        "errors": len(rows) - len(usable),
        "retried": sum((r[arm].get("attempts") or 1) > 1 for r in usable),
        "p50_ms": statistics.median(times), "p95_ms": percentile(times, 0.95),
        "output_tokens": statistics.mean(r[arm]["tokens"].get("output_tokens") or 0 for r in usable),
        "cost_per_1k": 1000 * statistics.mean(costs),
    }


def classification():
    groups = defaultdict(list)
    for root in CLASSIFICATION:
        reasoning = "low" if root.name.endswith("reasoning-low") else "off"
        for path in sorted(root.glob("*.json")):
            data = json.loads(path.read_text())
            groups[(data["model"], data["config"], reasoning)].append(score(data["model"], data["records"]))
    rows = []
    for (model, config, reasoning), runs in sorted(groups.items()):
        mean = lambda key: statistics.mean(run[key] for run in runs) if runs[0][key] is not None else None
        rows.append({"model": model, "config": config, "reasoning": reasoning, "passes": len(runs),
                     "ag_news": mean("ag_news"), "ag_news_range": [min(r["ag_news"] for r in runs), max(r["ag_news"] for r in runs)],
                     **{key: mean(key) for key in ("sst2", "brier", "errors", "retried", "p50_ms", "p95_ms",
                                                   "output_tokens", "cost_per_1k")}})
    return rows


def sdb():
    """Untimed accuracy from SDB's own scorer; latency and cost from the answer files."""
    sdb_dir = HARNESS / "sdb"
    files = sorted(str(path) for path in (sdb_dir / "answers").glob("*haiku-5.5*.jsonl"))
    output = subprocess.run(["python3", "score.py", "--json", *files], cwd=sdb_dir, capture_output=True, text=True,
                            check=True)
    rows = []
    for setting, passes in json.loads(output.stdout).items():
        records = [json.loads(line) for path in files if Path(path).name.startswith(setting + ".pass")
                   for line in Path(path).read_text().splitlines()]
        times = [r["ms"] for r in records if r.get("ms") is not None and not r.get("error")]
        input_price, output_price = PRICES["anthropic/claude-haiku-5.5"]
        cost = sum((r.get("usage") or {}).get("cost") or
                   ((r.get("usage") or {}).get("input_tokens") or 0) * input_price / 1e6 +
                   (((r.get("usage") or {}).get("output_tokens") or 0) +
                    ((r.get("usage") or {}).get("thinking_tokens") or 0)) * output_price / 1e6 for r in records)
        rows.append({"setting": setting, "passes": len(passes),
                     "untimed": statistics.mean(p["untimed"] for p in passes),
                     "untimed_range": [min(p["untimed"] for p in passes), max(p["untimed"] for p in passes)],
                     "invalid": statistics.mean(p["invalid_or_missing"] for p in passes),
                     "p50_ms": statistics.median(times), "p95_ms": percentile(times, 0.95),
                     "cost_per_1k_states": 1000 * cost / len(records)})
    return rows


if __name__ == "__main__":
    summary = {"classification": classification(), "stream_decision_bench": sdb()}
    (HERE / "data" / "haiku-5-5.json").write_text(json.dumps(summary, indent=1) + "\n")
    for row in summary["classification"]:
        print(f"{row['model']:28} {row['config']:22} {row['reasoning']:4} n={row['passes']} "
              f"AG {row['ag_news']:.1f} {row['ag_news_range']} SST {row['sst2']:.1f} "
              f"Brier {row['brier'] if row['brier'] is None else round(row['brier'], 3)} err {row['errors']:.1f} "
              f"retry {row['retried']:.1f} p50 {row['p50_ms']:.0f} p95 {row['p95_ms']:.0f} "
              f"out {row['output_tokens']:.0f} $/1k {row['cost_per_1k']:.3f}")
    for row in summary["stream_decision_bench"]:
        print(f"{row['setting']:60} n={row['passes']} untimed {row['untimed']:.2f}% invalid {row['invalid']:.1f} "
              f"p50 {row['p50_ms']:.0f} p95 {row['p95_ms']:.0f} $/1k {row['cost_per_1k_states']:.3f}")
