#!/usr/bin/env python3
"""Evaluate realtime Q&A predictions against a MultiQT manifest."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from common import (
    DEFAULT_LABELS_PATH,
    binary_metrics,
    load_labels,
    percentile,
    read_jsonl,
    safe_div,
    truth_for_row,
    write_json,
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--predictions", required=True, type=Path)
    parser.add_argument("--labels", type=Path, default=DEFAULT_LABELS_PATH)
    parser.add_argument("--threshold", type=float, default=0.5)
    parser.add_argument("--latency-field", default="decision_ms")
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument("--no-gates", action="store_true", help="Return success after printing metrics, useful for tiny smoke fixtures.")
    args = parser.parse_args()

    labels = load_labels(args.labels)
    rows = read_jsonl(args.manifest)
    predictions_raw = read_jsonl(args.predictions)
    predicted, scores, latencies = parse_predictions(predictions_raw, args.threshold, args.latency_field)

    metrics = binary_metrics(rows, predicted, labels)
    metrics["threshold"] = args.threshold
    metrics["latency_ms"] = {
        "p50": percentile(latencies, 0.50),
        "p95": percentile(latencies, 0.95),
        "p99": percentile(latencies, 0.99),
    }
    metrics["by_language"] = metrics_by_key(rows, predicted, labels, "language")
    metrics["by_label"] = metrics_by_key(rows, predicted, labels, "label")
    metrics["score_summary"] = {
        "count": len(scores),
        "p50": percentile(scores, 0.50),
        "p95": percentile(scores, 0.95),
        "p99": percentile(scores, 0.99),
    }

    payload = {"metrics": metrics, "gates": gate_results(metrics)}
    rendered = json.dumps(payload, indent=2, sort_keys=True)
    print(rendered)
    if args.out:
        write_json(args.out, payload)
    return 0 if args.no_gates or all(payload["gates"].values()) else 1


def parse_predictions(
    rows: list[dict[str, Any]],
    threshold: float,
    latency_field: str,
) -> tuple[dict[str, bool], list[float], list[float]]:
    predicted: dict[str, bool] = {}
    scores: list[float] = []
    latencies: list[float] = []
    for row in rows:
        row_id = str(row.get("id", ""))
        if "response_needed" in row:
            predicted[row_id] = bool(row["response_needed"])
        elif "responseNeeded" in row:
            predicted[row_id] = bool(row["responseNeeded"])
        else:
            score = float(row.get("score", row.get("decision_score", 0.0)))
            scores.append(score)
            predicted[row_id] = score >= threshold
        if latency_field in row and row[latency_field] is not None:
            latencies.append(float(row[latency_field]))
    return predicted, scores, latencies


def metrics_by_key(
    rows: list[dict[str, Any]],
    predictions: dict[str, bool],
    labels: dict[str, Any],
    key: str,
) -> dict[str, dict[str, float | int]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        grouped.setdefault(str(row.get(key, "missing")), []).append(row)

    output: dict[str, dict[str, float | int]] = {}
    for value, group in grouped.items():
        subset_predictions = {str(row.get("id", "")): predictions.get(str(row.get("id", "")), False) for row in group}
        counts = binary_counts(group, subset_predictions, labels)
        counts["precision"] = safe_div(counts["tp"], counts["tp"] + counts["fp"])
        counts["recall"] = safe_div(counts["tp"], counts["tp"] + counts["fn"])
        output[value] = counts
    return output


def binary_counts(
    rows: list[dict[str, Any]],
    predictions: dict[str, bool],
    labels: dict[str, Any],
) -> dict[str, int]:
    tp = fp = fn = tn = 0
    for row in rows:
        truth = truth_for_row(row, labels)
        predicted = predictions.get(str(row.get("id", "")), False)
        if predicted and truth:
            tp += 1
        elif predicted and not truth:
            fp += 1
        elif not predicted and truth:
            fn += 1
        else:
            tn += 1
    return {"tp": tp, "fp": fp, "fn": fn, "tn": tn}


def gate_results(metrics: dict[str, Any]) -> dict[str, bool]:
    latency = metrics.get("latency_ms", {})
    p95 = latency.get("p95")
    p99 = latency.get("p99")
    per_language = metrics.get("by_language", {})
    language_gates = [
        values.get("precision", 0.0) >= 0.990 and values.get("recall", 0.0) >= 0.950
        for language, values in per_language.items()
        if language in {"pt-BR", "en-US", "es-ES", "ja-JP"}
    ]
    return {
        "precision_gte_0_995": metrics.get("precision", 0.0) >= 0.995,
        "recall_gte_0_970": metrics.get("recall", 0.0) >= 0.970,
        "critical_negative_fp_zero": metrics.get("critical_negative_false_positives", 1) == 0,
        "per_language_gates": bool(language_gates) and all(language_gates),
        "p95_lte_60ms": p95 is None or p95 <= 60.0,
        "p99_lte_100ms": p99 is None or p99 <= 100.0,
    }


if __name__ == "__main__":
    raise SystemExit(main())
