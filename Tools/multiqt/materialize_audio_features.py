#!/usr/bin/env python3
"""Materialize privacy-safe log-mel features for MultiQT manifests.

The input manifest may reference local audio files. This tool writes fixed-size
`.npy` log-mel tensors and emits a parallel manifest that can be trained without
reading raw audio again. It is intended for synthetic/public/consented datasets;
the generated manifest can redact `audio_path` while preserving
`audio_feature_path`.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

try:
    import numpy as np
    import torch
    import torchaudio
except ImportError as error:  # pragma: no cover - executed only on training machines.
    raise SystemExit(
        "Missing audio feature dependencies. Install with: "
        "python3 -m pip install -r Tools/multiqt/requirements.txt"
    ) from error

from common import read_jsonl, write_json, write_jsonl


SPLITS = ("train", "dev", "test", "hard_test")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", required=True, type=Path)
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument("--audio-root", type=Path, default=None)
    parser.add_argument("--sample-rate", type=int, default=16000)
    parser.add_argument("--max-frames", type=int, default=240)
    parser.add_argument("--feature-source", choices=["logmel", "synthetic_logmel"], default="synthetic_logmel")
    parser.add_argument("--crop-segments", action="store_true", help="Crop audio by start_ms/end_ms before feature extraction.")
    parser.add_argument(
        "--redact-audio-path",
        action="store_true",
        help="Replace audio_path with a non-existing placeholder after feature extraction.",
    )
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    feature_dir = args.out_dir / "features"
    feature_dir.mkdir(parents=True, exist_ok=True)
    audio_root = args.audio_root or args.input_dir
    mel = torchaudio.transforms.MelSpectrogram(
        sample_rate=args.sample_rate,
        n_fft=400,
        win_length=320,
        hop_length=160,
        n_mels=40,
    )
    report: dict[str, Any] = {
        "input_dir": str(args.input_dir),
        "audio_root": str(audio_root),
        "sample_rate": args.sample_rate,
        "max_frames": args.max_frames,
        "feature_source": args.feature_source,
        "crop_segments": args.crop_segments,
        "redact_audio_path": args.redact_audio_path,
        "splits": {},
    }

    for split in SPLITS:
        input_path = args.input_dir / f"{split}.jsonl"
        if not input_path.exists():
            continue
        rows = read_jsonl(input_path)
        output_rows: list[dict[str, Any]] = []
        materialized = copied_proxy = reused = 0
        for row in rows:
            output = dict(row)
            if output.get("audio_feature_source") == "signal_proxy":
                output_rows.append(output)
                copied_proxy += 1
                continue

            feature_path = feature_dir / f"{safe_feature_id(str(output['id']))}.npy"
            if not feature_path.exists():
                audio_path = resolve_audio_path(output, audio_root)
                feature = extract_logmel(
                    audio_path,
                    mel=mel,
                    sample_rate=args.sample_rate,
                    max_frames=args.max_frames,
                    start_ms=int(output.get("start_ms", 0)),
                    end_ms=int(output.get("end_ms", 0)),
                    crop_segment=args.crop_segments,
                )
                np.save(feature_path, feature.astype(np.float32, copy=False))
                materialized += 1
            else:
                reused += 1

            output["audio_feature_path"] = relative_path(feature_path, args.out_dir)
            output["audio_feature_source"] = args.feature_source
            if args.redact_audio_path:
                output["audio_path"] = f"redacted_audio/{safe_feature_id(str(output['id']))}.wav"
            output_rows.append(output)

        write_jsonl(args.out_dir / f"{split}.jsonl", output_rows)
        report["splits"][split] = {
            "rows": len(output_rows),
            "materialized": materialized,
            "reused": reused,
            "copied_signal_proxy": copied_proxy,
        }

    write_json(args.out_dir / "feature_materialization_report.json", report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


def resolve_audio_path(row: dict[str, Any], audio_root: Path) -> Path:
    audio_path = Path(str(row["audio_path"]))
    if not audio_path.is_absolute():
        audio_path = audio_root / audio_path
    if not audio_path.exists():
        raise FileNotFoundError(f"audio file not found for {row.get('id')}: {audio_path}")
    return audio_path


def extract_logmel(
    audio_path: Path,
    mel: torchaudio.transforms.MelSpectrogram,
    sample_rate: int,
    max_frames: int,
    start_ms: int,
    end_ms: int,
    crop_segment: bool,
) -> np.ndarray:
    waveform, source_rate = torchaudio.load(audio_path)
    waveform = waveform.mean(dim=0, keepdim=True)
    if source_rate != sample_rate:
        waveform = torchaudio.functional.resample(waveform, source_rate, sample_rate)
    if crop_segment and end_ms > start_ms:
        start_sample = max(0, int(start_ms * sample_rate / 1000))
        end_sample = min(waveform.shape[1], int(end_ms * sample_rate / 1000))
        if end_sample > start_sample:
            waveform = waveform[:, start_sample:end_sample]
    features = torch.log1p(mel(waveform)).squeeze(0)
    features = fit_frames(features, max_frames)
    mean = features.mean()
    std = features.std().clamp_min(1e-4)
    normalized = (features - mean) / std
    return normalized.cpu().numpy()


def fit_frames(features: torch.Tensor, max_frames: int) -> torch.Tensor:
    if features.shape[1] > max_frames:
        return features[:, :max_frames]
    if features.shape[1] < max_frames:
        pad = torch.zeros(features.shape[0], max_frames - features.shape[1], dtype=features.dtype)
        return torch.cat([features, pad], dim=1)
    return features


def safe_feature_id(row_id: str) -> str:
    readable = "".join(character if character.isalnum() or character in {"-", "_"} else "-" for character in row_id)
    digest = hashlib.sha256(row_id.encode("utf-8")).hexdigest()[:10]
    return f"{readable[:96]}-{digest}"


def relative_path(path: Path, root: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


if __name__ == "__main__":
    raise SystemExit(main())
