"""Recalculate the Claude Haiku 4.5 and one-call instruction benchmarks."""

import json
import math
from pathlib import Path
import statistics

DATA = Path(__file__).parent / "data"
RUNS = (
    ("Haiku, one call", "haiku-one-call.json", "single_request"),
    ("Haiku, ratings", "haiku-ratings.json", "ratings"),
    ("Luna, one call, 0.1.2 instructions", "luna-one-call-old-instructions.json", "single_request"),
    ("Luna, one call, 0.1.3 instructions", "luna-one-call-new-instructions.json", "single_request"),
)


def label(value):
    return "positive" if value > 0.5 else "negative" if value < 0.5 else "tie"


for title, filename, arm in RUNS:
    rows = json.loads((DATA / filename).read_text())["records"]
    usable = [row for row in rows if "answers" in row[arm]]
    news = [row for row in usable if row["id"].startswith("agnews:")]
    sst = [row for row in usable if row["id"].startswith("sst2:")]

    topic = [row[arm]["answers"]["topic"] for row in news]
    correct = sum(answer["choice"] == row["expected"] for answer, row in zip(topic, news))
    brier = statistics.mean(sum((value - (key == row["expected"])) ** 2
                                for key, value in answer["probabilities"].items())
                            for answer, row in zip(topic, news))
    choice = sum(row[arm]["answers"]["sentiment"]["choice"] == row["expected"] for row in sst)
    probability = sum(label(row[arm]["answers"]["positive"]["probability"]) == row["expected"] for row in sst)
    score = sum(label(row[arm]["answers"]["valence"]["score"]) == row["expected"] for row in sst)
    sst_brier = statistics.mean((row[arm]["answers"]["sentiment"]["probabilities"]["positive"] -
                                 (row["expected"] == "positive")) ** 2 for row in sst)
    times = sorted(row[arm]["ms"] for row in usable)
    retried = sum((row[arm].get("attempts") or 1) > 1 for row in usable)
    ties = sum(row[arm].get("tie_breaks") or 0 for row in usable)
    print(title)
    print(f"  AG News correct={correct}/64 usable={len(news)}/64 brier={brier:.4f}")
    print(f"  SST-2 choice={choice}/32 probability={probability}/32 score={score}/32 "
          f"usable={len(sst)}/32 brier={sst_brier:.4f}")
    print(f"  median={statistics.median(times):,.0f}ms p90={times[math.ceil(0.9 * len(times)) - 1]:,.0f}ms "
          f"retried={retried} tie_breaks={ties}")
