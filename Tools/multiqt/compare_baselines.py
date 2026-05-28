#!/usr/bin/env python3
"""Train comparable MultiQT variants and report baseline gates.

This is intentionally a training-orchestration tool, not a runtime benchmark.
It makes the final model claim auditable by training text-only and audio-only
variants with the same split, seed, architecture size, and threshold policy.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

from common import DEFAULT_LABELS_PATH, binary_metrics, load_labels, percentile, read_jsonl, write_json
from model import AUDIO_ENCODERS, MODEL_INPUT_MODES


DEFAULT_MODES = ("multimodal", "text_only", "audio_only")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--dev", required=True, type=Path)
    parser.add_argument("--test", required=True, type=Path)
    parser.add_argument("--hard-test", type=Path, default=None)
    parser.add_argument("--labels", type=Path, default=DEFAULT_LABELS_PATH)
    parser.add_argument("--audio-root", type=Path, default=None)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--modes", nargs="+", choices=MODEL_INPUT_MODES, default=list(DEFAULT_MODES))
    parser.add_argument("--epochs", type=int, default=16)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--max-tokens", type=int, default=96)
    parser.add_argument("--max-frames", type=int, default=240)
    parser.add_argument("--audio-encoder", choices=AUDIO_ENCODERS, default="temporal_cnn")
    parser.add_argument("--positive-weight", type=float, default=1.0)
    parser.add_argument("--critical-negative-weight", type=float, default=2.5)
    parser.add_argument("--min-threshold", type=float, default=0.50)
    parser.add_argument("--device", choices=["auto", "cpu", "mps"], default="auto")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--skip-existing", action="store_true")
    parser.add_argument("--no-gates", action="store_true", help="Print/report results but do not fail the process.")
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    summaries: dict[str, Any] = {}
    for mode in args.modes:
        mode_out = args.out / mode
        if not args.skip_existing or not (mode_out / "metrics.json").exists():
            train_variant(args, mode, mode_out)
        summaries[mode] = summarize_variant(args, mode_out)

    payload = {
        "modes": list(args.modes),
        "summaries": summaries,
        "gates": gate_results(summaries),
        "promotion": promotion_results(summaries),
    }
    write_json(args.out / "baseline_comparison.json", payload)
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0 if args.no_gates or all(payload["gates"].values()) else 1


def train_variant(args: argparse.Namespace, mode: str, mode_out: Path) -> None:
    command = [
        sys.executable,
        str(Path(__file__).with_name("train.py")),
        "--manifest",
        str(args.manifest),
        "--dev",
        str(args.dev),
        "--test",
        str(args.test),
        "--labels",
        str(args.labels),
        "--out",
        str(mode_out),
        "--epochs",
        str(args.epochs),
        "--batch-size",
        str(args.batch_size),
        "--learning-rate",
        str(args.learning_rate),
        "--max-tokens",
        str(args.max_tokens),
        "--max-frames",
        str(args.max_frames),
        "--audio-encoder",
        str(args.audio_encoder),
        "--seed",
        str(args.seed),
        "--positive-weight",
        str(args.positive_weight),
        "--critical-negative-weight",
        str(args.critical_negative_weight),
        "--min-threshold",
        str(args.min_threshold),
        "--device",
        str(args.device),
        "--input-mode",
        mode,
    ]
    if args.hard_test:
        command.extend(["--hard-test", str(args.hard_test)])
    if args.audio_root:
        command.extend(["--audio-root", str(args.audio_root)])
    subprocess.run(command, check=True)


def summarize_variant(args: argparse.Namespace, mode_out: Path) -> dict[str, Any]:
    metrics = json.loads((mode_out / "metrics.json").read_text(encoding="utf-8"))
    threshold = float(metrics["threshold"])
    labels = load_labels(args.labels)
    summary: dict[str, Any] = {
        "input_mode": metrics.get("input_mode", mode_out.name),
        "threshold": threshold,
        "test": split_metrics(args.test, mode_out / "test_predictions.jsonl", threshold, labels),
    }
    if args.hard_test and (mode_out / "hard_test_predictions.jsonl").exists():
        summary["hard_test"] = split_metrics(args.hard_test, mode_out / "hard_test_predictions.jsonl", threshold, labels)
    return summary


def split_metrics(
    manifest_path: Path,
    predictions_path: Path,
    threshold: float,
    labels: dict[str, Any],
) -> dict[str, Any]:
    manifest_rows = read_jsonl(manifest_path)
    predictions = read_jsonl(predictions_path)
    predicted: dict[str, bool] = {}
    latencies: list[float] = []
    for row in predictions:
        score = float(row.get("score", 0))
        predicted[str(row.get("id", ""))] = score >= threshold
        if "decision_ms" in row:
            latencies.append(float(row["decision_ms"]))
    metrics = binary_metrics(manifest_rows, predicted, labels)
    metrics["latency_ms"] = {
        "p50": percentile(latencies, 0.50),
        "p95": percentile(latencies, 0.95),
        "p99": percentile(latencies, 0.99),
    }
    return metrics


def gate_results(summaries: dict[str, Any]) -> dict[str, bool]:
    if "multimodal" not in summaries:
        return {"multimodal_present": False}
    gates: dict[str, bool] = {"multimodal_present": True}
    multimodal = summaries["multimodal"]
    baseline_modes = [mode for mode in summaries if mode != "multimodal"]
    for split in ("test", "hard_test"):
        if split not in multimodal:
            continue
        multi_metrics = multimodal[split]
        gates[f"{split}_multimodal_precision_gte_0_995"] = float(multi_metrics["precision"]) >= 0.995
        gates[f"{split}_multimodal_recall_gte_0_970"] = float(multi_metrics["recall"]) >= 0.970
        gates[f"{split}_multimodal_critical_fp_zero"] = int(multi_metrics["critical_negative_false_positives"]) == 0
        gates[f"{split}_multimodal_p95_lte_60ms"] = latency_at(multi_metrics, "p95") <= 60.0
        gates[f"{split}_multimodal_p99_lte_100ms"] = latency_at(multi_metrics, "p99") <= 100.0
        for language, language_metrics in multi_metrics.get("by_language", {}).items():
            gates[f"{split}_{language}_precision_gte_0_990"] = float(language_metrics["precision"]) >= 0.990
            gates[f"{split}_{language}_recall_gte_0_950"] = float(language_metrics["recall"]) >= 0.950
            gates[f"{split}_{language}_critical_fp_zero"] = int(language_metrics["critical_negative_false_positives"]) == 0
        for label, label_metrics in multi_metrics.get("by_label", {}).items():
            gates[f"{split}_{label}_critical_fp_zero"] = int(label_metrics["critical_negative_false_positives"]) == 0
        for mode in baseline_modes:
            if split not in summaries[mode]:
                continue
            baseline = summaries[mode][split]
            gates[f"{split}_precision_safe_vs_{mode}"] = precision_safe_vs_baseline(multi_metrics, baseline)
            gates[f"{split}_recall_above_absolute_gate_vs_{mode}"] = float(multi_metrics["recall"]) >= 0.970
            gates[f"{split}_critical_fp_not_worse_than_{mode}"] = int(multi_metrics["critical_negative_false_positives"]) <= int(baseline["critical_negative_false_positives"])
    return gates


def latency_at(metrics: dict[str, Any], key: str) -> float:
    value = metrics.get("latency_ms", {}).get(key)
    return float(value) if value is not None else float("inf")


def promotion_results(summaries: dict[str, Any]) -> dict[str, bool]:
    gates = gate_results(summaries)
    results: dict[str, bool] = {
        "absolute_gates_pass": all(gates.values()),
        "text_only_present": "text_only" in summaries,
    }
    if "multimodal" not in summaries or "text_only" not in summaries:
        results["beats_text_only_on_any_split"] = False
        results["promote_to_enforced"] = False
        return results

    multimodal = summaries["multimodal"]
    text_only = summaries["text_only"]
    split_gains: list[bool] = []
    for split in ("test", "hard_test"):
        if split not in multimodal or split not in text_only:
            continue
        multi_metrics = multimodal[split]
        text_metrics = text_only[split]
        precision_gain = float(multi_metrics["precision"]) > float(text_metrics["precision"]) + 1e-9
        critical_fp_gain = int(multi_metrics["critical_negative_false_positives"]) < int(text_metrics["critical_negative_false_positives"])
        recall_gain = float(multi_metrics["recall"]) > float(text_metrics["recall"]) + 1e-9
        precision_first_gain = (precision_gain or critical_fp_gain) and float(multi_metrics["recall"]) >= 0.970
        results[f"{split}_beats_text_only"] = precision_first_gain or recall_gain
        results[f"{split}_precision_first_gain"] = precision_first_gain
        split_gains.append(precision_first_gain or recall_gain)
    results["beats_text_only_on_any_split"] = any(split_gains)
    results["promote_to_enforced"] = results["absolute_gates_pass"] and results["beats_text_only_on_any_split"]
    return results


def precision_safe_vs_baseline(multi_metrics: dict[str, Any], baseline: dict[str, Any]) -> bool:
    multi_precision = float(multi_metrics["precision"])
    baseline_precision = float(baseline["precision"])
    multi_critical_fp = int(multi_metrics["critical_negative_false_positives"])
    baseline_critical_fp = int(baseline["critical_negative_false_positives"])
    return multi_precision + 1e-9 >= baseline_precision or (
        multi_precision >= 0.995 and multi_critical_fp < baseline_critical_fp
    )


if __name__ == "__main__":
    raise SystemExit(main())
