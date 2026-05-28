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
from common import write_json


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    checkpoint = torch.load(args.checkpoint, map_location="cpu")
    config = checkpoint["config"]
    model = MultiQTConcatModel(
        vocab_size=len(checkpoint["vocab"]),
        label_count=len(checkpoint["labels"]),
        scalar_count=int(config["scalar_count"]),
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
    write_json(
        metadata_out,
        {
            "model_resource_name": args.out.stem,
            "labels": checkpoint["labels"],
            "vocab": checkpoint["vocab"],
            "threshold": checkpoint.get("threshold", 0.5),
            "config": checkpoint["config"],
            "inputs": {
                "text_tokens": [1, max_tokens],
                "audio_logmel": [1, 40, max_frames],
                "scalars": [1, scalar_count],
            },
            "outputs": ["response_logit", "label_logits", "complete_logit", "rhetorical_logit"],
        },
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
