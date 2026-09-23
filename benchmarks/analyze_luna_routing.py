"""Recalculate the published Luna routing table from credential-free results."""

import json
import math
import statistics
from pathlib import Path

DATA = Path(__file__).parent / "data"


def records(name):
    return json.loads((DATA / name).read_text())["records"]


def summarize(label, cases):
    print(label)
    for route in ("default", "latency_sort"):
        usable = [case for case in cases if "ms" in case["routes"][route]]
        latency = sorted(case["routes"][route]["ms"] for case in usable)
        correct = sum(case["routes"][route]["choice"] == case["expected"] for case in usable)
        errors = []
        for case in usable:
            probabilities = case["routes"][route]["probabilities"]
            expected = case["expected"]
            squared = sum((value - (choice == expected)) ** 2 for choice, value in probabilities.items())
            errors.append(squared / 2 if label == "SST-2" else squared)
        print(
            route,
            f"correct={correct}/{len(cases)}",
            f"usable={len(usable)}/{len(cases)}",
            f"median={statistics.median(latency):.1f}ms",
            f"p90={latency[math.ceil(0.9 * len(latency)) - 1]:.1f}ms",
            f"brier={statistics.mean(errors):.4f}",
        )
    differences = [
        case["routes"]["latency_sort"]["ms"] - case["routes"]["default"]["ms"]
        for case in cases
        if all("ms" in case["routes"][route] for route in ("default", "latency_sort"))
    ]
    print(f"paired_faster={sum(value < 0 for value in differences)}/{len(differences)}")
    print(f"median_paired_difference={statistics.median(differences):.1f}ms")


summarize("AG News", records("luna-routing-agnews-1.json") + records("luna-routing-agnews-2.json"))
summarize("SST-2", records("luna-routing-sst2.json"))
