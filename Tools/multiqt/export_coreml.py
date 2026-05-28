#!/usr/bin/env python3
"""Export a trained Notchly MultiQT checkpoint to Core ML."""

from __future__ import annotations

import argparse
from pathlib import Path

try:
    import coremltools as ct
    import numpy as np
    import torch
except ImportError as error:  # pragma: no cover - executed only on export machines.
    raise SystemExit(
        "Missing export dependencies. Install with: "
        "python3 -m pip install -r Tools/multiqt/requirements.txt"
    ) from error

from model import MultiQTConcatModel
from common import DEFAULT_LABELS_PATH, load_labels, write_json


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--labels", type=Path, default=DEFAULT_LABELS_PATH)
    parser.add_argument("--training-report", type=Path, default=None)
    parser.add_argument("--baseline-comparison", type=Path, default=None)
    args = parser.parse_args()

    checkpoint = torch.load(args.checkpoint, map_location="cpu")
    label_policy = checkpoint.get("label_policy") or load_labels(args.labels)
    config = checkpoint["config"]
    model = MultiQTConcatModel(
        vocab_size=len(checkpoint["vocab"]),
        label_count=len(checkpoint["labels"]),
        scalar_count=int(config["scalar_count"]),
        input_mode=str(config.get("input_mode", "multimodal")),
    )
    model.load_state_dict(checkpoint["model_state"])
    model.eval()

    max_tokens = int(config["max_tokens"])
    max_frames = int(config["max_frames"])
    scalar_count = int(config["scalar_count"])
    example = (
        torch.zeros(1, max_tokens, dtype=torch.long),
        torch.zeros(1, 40, max_frames, dtype=torch.float32),
        torch.zeros(1, scalar_count, dtype=torch.float32),
    )
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        inputs=[
            ct.TensorType(name="text_tokens", shape=example[0].shape, dtype=np.int32),
            ct.TensorType(name="audio_logmel", shape=example[1].shape, dtype=np.float32),
            ct.TensorType(name="scalars", shape=example[2].shape, dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="response_logit"),
            ct.TensorType(name="label_logits"),
            ct.TensorType(name="complete_logit"),
            ct.TensorType(name="rhetorical_logit"),
        ],
    )
    args.out.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(args.out))
    metadata_out = args.out.with_name(f"{args.out.stem}.metadata.json")
    threshold = checkpoint.get("threshold", 0.5)
    language_thresholds = checkpoint.get("language_thresholds") or {
        language: threshold
        for language in label_policy.get("languages", [])
    }
    write_json(
        metadata_out,
        {
            "model_resource_name": args.out.stem,
            "labels": checkpoint["labels"],
            "label_policy": label_policy,
            "vocab": checkpoint["vocab"],
            "threshold": threshold,
            "language_thresholds": language_thresholds,
            "config": checkpoint["config"],
            "calibration": {
                "dev_metrics": checkpoint.get("dev_metrics"),
                "dev_gates": checkpoint.get("dev_gates"),
                "language_thresholds": language_thresholds,
            },
            "inputs": {
                "text_tokens": [1, max_tokens],
                "audio_logmel": [1, 40, max_frames],
                "scalars": [1, scalar_count],
            },
            "audio_feature_contract": {
                "bands": 40,
                "max_frames": max_frames,
                "raw_audio_persisted": False,
                "runtime_fallback": "signal_proxy",
                "description": "Runtime uses captured log-mel features when attached to QuestionMultimodalSignal, otherwise a numeric proxy from RMS/peak/energy/noise/temporal features.",
            },
            "outputs": ["response_logit", "label_logits", "complete_logit", "rhetorical_logit"],
            "training_report": load_optional_json(args.training_report),
            "baseline_comparison": compact_baseline_comparison(load_optional_json(args.baseline_comparison)),
        },
    )
    return 0


def load_optional_json(path: Path | None) -> dict | None:
    if path is None:
        return None
    import json

    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    return payload if isinstance(payload, dict) else None


def compact_baseline_comparison(payload: dict | None) -> dict | None:
    if payload is None:
        return None
    summaries = {}
    for mode, summary in payload.get("summaries", {}).items():
        summaries[mode] = {
            "threshold": summary.get("threshold"),
            "input_mode": summary.get("input_mode"),
            "test": compact_split_metrics(summary.get("test")),
            "hard_test": compact_split_metrics(summary.get("hard_test")),
        }
    return {
        "modes": payload.get("modes"),
        "gates": payload.get("gates"),
        "promotion": payload.get("promotion"),
        "summaries": summaries,
    }


def compact_split_metrics(metrics: dict | None) -> dict | None:
    if metrics is None:
        return None
    return {
        "tp": metrics.get("tp"),
        "fp": metrics.get("fp"),
        "fn": metrics.get("fn"),
        "tn": metrics.get("tn"),
        "precision": metrics.get("precision"),
        "recall": metrics.get("recall"),
        "critical_negative_false_positives": metrics.get("critical_negative_false_positives"),
        "latency_ms": metrics.get("latency_ms"),
        "by_language": metrics.get("by_language"),
        "by_label": metrics.get("by_label"),
    }


if __name__ == "__main__":
    raise SystemExit(main())
