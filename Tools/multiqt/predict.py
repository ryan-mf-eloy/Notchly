#!/usr/bin/env python3
"""Run a trained MultiQT checkpoint over a manifest and emit prediction JSONL."""

from __future__ import annotations

import argparse
from pathlib import Path

try:
    import torch
except ImportError as error:  # pragma: no cover - executed only on training machines.
    raise SystemExit(
        "Missing prediction dependencies. Install with: "
        "python3 -m pip install -r Tools/multiqt/requirements.txt"
    ) from error

from common import read_jsonl, write_jsonl
from model import MultiQTConcatModel
from train import MultiQTDataset, prediction_rows, predict


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--audio-root", type=Path, default=None)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--batch-size", type=int, default=16)
    args = parser.parse_args()

    checkpoint = torch.load(args.checkpoint, map_location="cpu")
    config = checkpoint["config"]
    label_to_id = {label: index for index, label in enumerate(checkpoint["labels"])}
    rows = read_jsonl(args.manifest)
    dataset = MultiQTDataset(
        rows,
        checkpoint["vocab"],
        label_to_id,
        args.audio_root or args.manifest.parent,
        int(config["max_tokens"]),
        int(config["max_frames"]),
    )
    model = MultiQTConcatModel(
        vocab_size=len(checkpoint["vocab"]),
        label_count=len(checkpoint["labels"]),
        scalar_count=int(config["scalar_count"]),
    )
    model.load_state_dict(checkpoint["model_state"])
    model.eval()
    predictions = predict(model, dataset, args.batch_size)
    write_jsonl(args.out, prediction_rows(rows, predictions))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
