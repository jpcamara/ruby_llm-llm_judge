"""Recalculate the direct OpenAI versus OpenRouter Luna benchmark."""

import json
import math
from pathlib import Path
import statistics

RESULTS = Path(__file__).parent / "data/luna-direct-vs-openrouter.json"
rows = json.loads(RESULTS.read_text())["records"]

for name, prefix in (("AG News", "agnews:"), ("SST-2", "sst2:")):
    cases = [row for row in rows if row["id"].startswith(prefix)]
    print(name, len(cases))
    for route in ("openai_direct", "openrouter_latency"):
        usable = [row for row in cases if "choice" in row["routes"][route]]
        times = sorted(row["routes"][route]["ms"] for row in usable)
        correct = sum(row["routes"][route]["choice"] == row["expected"] for row in usable)
        errors = []
        for row in usable:
            probabilities = row["routes"][route]["probabilities"]
            squared = sum((value - (label == row["expected"])) ** 2
                          for label, value in probabilities.items())
            errors.append(squared / 2 if prefix == "sst2:" else squared)
        retries = sum(row["routes"][route].get("attempts", 1) > 1 for row in cases)
        print(route, f"correct={correct}/{len(cases)}", f"usable={len(usable)}/{len(cases)}",
              f"median={statistics.median(times):.1f}ms",
              f"p90={times[math.ceil(0.9 * len(times)) - 1]:.1f}ms",
              f"brier={statistics.mean(errors):.4f}", f"retries={retries}")
    differences = [row["routes"]["openai_direct"]["ms"] -
                   row["routes"]["openrouter_latency"]["ms"] for row in cases]
    print(f"direct_faster={sum(value < 0 for value in differences)}/{len(differences)}")
    print(f"median_paired_difference={statistics.median(differences):.1f}ms")
