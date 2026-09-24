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

first_by_id = {row["id"]: row for row in rows}
repeat_rows = json.loads((Path(__file__).parent / "data/luna-direct-openai-repeat.json").read_text())["records"]
for name, prefix in (("AG News", "agnews:"), ("SST-2", "sst2:")):
    cases = [row for row in repeat_rows if row["id"].startswith(prefix)]
    usable = [row for row in cases if "choice" in row["routes"]["openai_direct"]]
    times = sorted(row["routes"]["openai_direct"]["ms"] for row in usable)
    correct = sum(row["routes"]["openai_direct"]["choice"] == row["expected"] for row in usable)
    errors = []
    for row in usable:
        probabilities = row["routes"]["openai_direct"]["probabilities"]
        squared = sum((value - (label == row["expected"])) ** 2
                      for label, value in probabilities.items())
        errors.append(squared / 2 if prefix == "sst2:" else squared)
    retries = sum(row["routes"]["openai_direct"].get("attempts", 1) > 1 for row in cases)
    flips = sum(row["routes"]["openai_direct"].get("choice") !=
                first_by_id[row["id"]]["routes"]["openai_direct"].get("choice") for row in cases)
    print(name, "direct repeat", f"correct={correct}/{len(cases)}", f"usable={len(usable)}/{len(cases)}",
          f"median={statistics.median(times):.1f}ms",
          f"p90={times[math.ceil(0.9 * len(times)) - 1]:.1f}ms",
          f"brier={statistics.mean(errors):.4f}", f"retries={retries}", f"label_flips={flips}")
