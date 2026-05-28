#!/usr/bin/env python3
"""Shared utilities for the Notchly MultiQT training toolchain."""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any, Iterable


DEFAULT_LABELS_PATH = Path(__file__).with_name("labels.json")


def load_labels(path: Path = DEFAULT_LABELS_PATH) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for index, line in enumerate(handle, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                row = json.loads(stripped)
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{index}: invalid JSON: {error}") from error
            if not isinstance(row, dict):
                raise ValueError(f"{path}:{index}: expected object row")
            rows.append(row)
    return rows


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            json.dump(row, handle, sort_keys=True)
            handle.write("\n")


def truth_for_row(row: dict[str, Any], labels: dict[str, Any]) -> bool:
    if "response_needed" in row:
        return bool(row["response_needed"])
    if "responseNeeded" in row:
        return bool(row["responseNeeded"])
    return str(row.get("label", "")) in set(labels["positive_labels"])


def is_critical_negative(row: dict[str, Any], labels: dict[str, Any]) -> bool:
    if bool(row.get("critical_negative", False)):
        return True
    return str(row.get("label", "")) in set(labels["critical_negative_labels"])


def percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = (len(ordered) - 1) * q
    lower = math.floor(index)
    upper = math.ceil(index)
    if lower == upper:
        return ordered[int(index)]
    weight = index - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def safe_div(numerator: float, denominator: float) -> float:
    return numerator / denominator if denominator else 0.0


def binary_metrics(
    rows: list[dict[str, Any]],
    predictions: dict[str, bool],
    labels: dict[str, Any],
) -> dict[str, Any]:
    tp = fp = fn = tn = critical_fp = missing = 0
    errors: list[dict[str, Any]] = []
    by_language: dict[str, dict[str, Any]] = {}
    by_label: dict[str, dict[str, Any]] = {}

    for row in rows:
        row_id = str(row.get("id", ""))
        truth = truth_for_row(row, labels)
        if row_id not in predictions:
            missing += 1
            predicted = False
        else:
            predicted = predictions[row_id]

        language = str(row.get("language", "unknown"))
        label = str(row.get("label", "unknown"))
        critical_negative = is_critical_negative(row, labels)
        update_confusion(by_language.setdefault(language, empty_confusion()), predicted, truth, critical_negative)
        update_confusion(by_label.setdefault(label, empty_confusion()), predicted, truth, critical_negative)

        if predicted and truth:
            tp += 1
        elif predicted and not truth:
            fp += 1
            if critical_negative:
                critical_fp += 1
            if len(errors) < 25:
                errors.append(error_row(row, "FP"))
        elif not predicted and truth:
            fn += 1
            if len(errors) < 25:
                errors.append(error_row(row, "FN"))
        else:
            tn += 1

    precision = safe_div(tp, tp + fp)
    recall = safe_div(tp, tp + fn)
    return {
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "tn": tn,
        "missing_predictions": missing,
        "precision": precision,
        "recall": recall,
        "critical_negative_false_positives": critical_fp,
        "by_language": finalize_group_metrics(by_language),
        "by_label": finalize_group_metrics(by_label),
        "error_examples": errors,
    }


def empty_confusion() -> dict[str, Any]:
    return {"tp": 0, "fp": 0, "fn": 0, "tn": 0, "critical_negative_false_positives": 0}


def update_confusion(bucket: dict[str, Any], predicted: bool, truth: bool, critical_negative: bool) -> None:
    if predicted and truth:
        bucket["tp"] += 1
    elif predicted and not truth:
        bucket["fp"] += 1
        if critical_negative:
            bucket["critical_negative_false_positives"] += 1
    elif not predicted and truth:
        bucket["fn"] += 1
    else:
        bucket["tn"] += 1


def finalize_group_metrics(groups: dict[str, dict[str, Any]]) -> dict[str, dict[str, Any]]:
    output: dict[str, dict[str, Any]] = {}
    for key, metrics in sorted(groups.items()):
        tp = int(metrics["tp"])
        fp = int(metrics["fp"])
        fn = int(metrics["fn"])
        output[key] = {
            "tp": tp,
            "fp": fp,
            "fn": fn,
            "tn": int(metrics["tn"]),
            "precision": safe_div(tp, tp + fp),
            "recall": safe_div(tp, tp + fn),
            "critical_negative_false_positives": int(metrics["critical_negative_false_positives"]),
        }
    return output


def error_row(row: dict[str, Any], kind: str) -> dict[str, Any]:
    text = row.get("asr_transcript") or row.get("transcript") or row.get("text") or ""
    return {
        "kind": kind,
        "id": row.get("id"),
        "language": row.get("language"),
        "label": row.get("label"),
        "text": redact_text(str(text)),
    }


def redact_text(text: str, limit: int = 160) -> str:
    compact = " ".join(text.split())
    if len(compact) <= limit:
        return compact
    return compact[: limit - 3] + "..."
