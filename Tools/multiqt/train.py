#!/usr/bin/env python3
"""Train the Notchly MultiQT audio+text classifier."""

from __future__ import annotations

import argparse
from functools import lru_cache
import json
import math
import random
import re
import time
from pathlib import Path
from typing import Any

from common import DEFAULT_LABELS_PATH, binary_metrics, load_labels, read_jsonl, safe_div, write_json, write_jsonl

try:
    import numpy as np
    import torch
    import torchaudio
    from torch import nn
    from torch.utils.data import DataLoader, Dataset
except ImportError as error:  # pragma: no cover - executed only on training machines.
    raise SystemExit(
        "Missing training dependencies. Install with: "
        "python3 -m pip install -r Tools/multiqt/requirements.txt"
    ) from error

from model import AUDIO_ENCODERS, MODEL_INPUT_MODES, MultiQTConcatModel


TOKEN_RE = re.compile(r"[\w']+", re.UNICODE)
LANGUAGES = ["pt-BR", "en-US", "es-ES", "ja-JP"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--dev", required=True, type=Path)
    parser.add_argument("--test", required=True, type=Path)
    parser.add_argument("--hard-test", type=Path, default=None)
    parser.add_argument("--labels", type=Path, default=DEFAULT_LABELS_PATH)
    parser.add_argument("--audio-root", type=Path, default=None)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--epochs", type=int, default=16)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--max-tokens", type=int, default=96)
    parser.add_argument("--max-frames", type=int, default=600)
    parser.add_argument("--input-mode", choices=MODEL_INPUT_MODES, default="multimodal")
    parser.add_argument("--audio-encoder", choices=AUDIO_ENCODERS, default="temporal_cnn")
    parser.add_argument("--positive-weight", type=float, default=1.0)
    parser.add_argument("--critical-negative-weight", type=float, default=2.5)
    parser.add_argument(
        "--min-threshold",
        type=float,
        default=0.50,
        help="Lowest response threshold considered during calibration; keep high for precision-first promotion.",
    )
    parser.add_argument("--device", choices=["auto", "cpu", "mps"], default="auto")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = resolve_device(args.device)

    labels_config = load_labels(args.labels)
    label_names = (
        labels_config["positive_labels"]
        + labels_config["critical_negative_labels"]
        + labels_config["noncritical_negative_labels"]
    )
    label_to_id = {label: index for index, label in enumerate(label_names)}

    train_rows = read_jsonl(args.manifest)
    dev_rows = read_jsonl(args.dev)
    test_rows = read_jsonl(args.test)
    hard_rows = read_jsonl(args.hard_test) if args.hard_test else []
    vocab = build_vocab(train_rows, min_count=2, max_size=30000)

    audio_root = args.audio_root or args.manifest.parent
    train_data = MultiQTDataset(train_rows, vocab, label_to_id, audio_root, args.max_tokens, args.max_frames)
    dev_data = MultiQTDataset(dev_rows, vocab, label_to_id, args.audio_root or args.dev.parent, args.max_tokens, args.max_frames)
    test_data = MultiQTDataset(test_rows, vocab, label_to_id, args.audio_root or args.test.parent, args.max_tokens, args.max_frames)
    hard_data = MultiQTDataset(hard_rows, vocab, label_to_id, args.audio_root or args.hard_test.parent, args.max_tokens, args.max_frames) if args.hard_test else None

    model = MultiQTConcatModel(
        vocab_size=len(vocab),
        label_count=len(label_names),
        scalar_count=7,
        input_mode=args.input_mode,
        audio_encoder=args.audio_encoder,
    ).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate, weight_decay=0.01)
    response_loss = nn.BCEWithLogitsLoss(reduction="none")
    label_loss = nn.CrossEntropyLoss(reduction="none")
    binary_loss = nn.BCEWithLogitsLoss(reduction="none")

    best_dev: tuple[float, ...] = (-1.0,)
    best_state: dict[str, Any] | None = None
    args.out.mkdir(parents=True, exist_ok=True)

    for epoch in range(1, args.epochs + 1):
        model.train()
        total_loss = 0.0
        loader = DataLoader(train_data, batch_size=args.batch_size, shuffle=True)
        for batch in loader:
            batch = batch_to_device(batch, device)
            optimizer.zero_grad(set_to_none=True)
            response_logit, label_logits, complete_logit, rhetorical_logit = model(
                batch["text_tokens"],
                batch["audio_logmel"],
                batch["scalars"],
            )
            weights = sample_weights(batch, args.positive_weight, args.critical_negative_weight)
            loss = (
                weighted_mean(response_loss(response_logit, batch["response_needed"]), weights)
                + 0.45 * weighted_mean(label_loss(label_logits, batch["label_id"]), weights)
                + 0.20 * weighted_mean(binary_loss(complete_logit, batch["complete"]), weights)
                + 0.20 * weighted_mean(binary_loss(rhetorical_logit, batch["rhetorical"]), weights)
            )
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            total_loss += float(loss.detach().cpu())

        dev_predictions = predict(model, dev_data, args.batch_size, device)
        threshold, dev_metrics, dev_gates = tune_threshold(dev_rows, dev_predictions, labels_config, min_threshold=args.min_threshold)
        language_thresholds = tune_thresholds_by_group(
            dev_rows,
            dev_predictions,
            labels_config,
            key="language",
            expected_values=labels_config.get("languages", []),
            min_threshold=args.min_threshold,
        )
        score = calibration_score(dev_metrics, dev_gates, threshold)
        print(
            json.dumps(
                {
                    "epoch": epoch,
                    "loss": safe_div(total_loss, max(1, len(loader))),
                    "threshold": threshold,
                    "language_thresholds": language_thresholds,
                    "dev": dev_metrics,
                    "dev_gates": dev_gates,
                },
                sort_keys=True,
            )
        )
        if score > best_dev:
            best_dev = score
            best_state = {
                "model_state": clone_state_dict(model),
                "vocab": vocab,
                "labels": label_names,
                "label_policy": {
                    "positive_labels": labels_config.get("positive_labels", []),
                    "critical_negative_labels": labels_config.get("critical_negative_labels", []),
                    "noncritical_negative_labels": labels_config.get("noncritical_negative_labels", []),
                    "languages": labels_config.get("languages", []),
                },
                "threshold": threshold,
                "language_thresholds": language_thresholds,
                "dev_metrics": dev_metrics,
                "dev_gates": dev_gates,
                "config": {
                    "max_tokens": args.max_tokens,
                    "max_frames": args.max_frames,
                    "scalar_count": 7,
                    "input_mode": args.input_mode,
                    "audio_encoder": args.audio_encoder,
                    "audio_feature_sources": audio_feature_sources(train_rows),
                    "positive_weight": args.positive_weight,
                    "critical_negative_weight": args.critical_negative_weight,
                },
            }

    if best_state is None:
        raise SystemExit("Training produced no checkpoint")

    model.load_state_dict(best_state["model_state"])
    test_predictions = predict(model, test_data, args.batch_size, device)
    test_metrics = compute_metrics(test_rows, test_predictions, best_state["threshold"], labels_config)
    hard_metrics = None
    hard_predictions: list[dict[str, float | bool]] = []
    if hard_data is not None:
        hard_predictions = predict(model, hard_data, args.batch_size, device)
        hard_metrics = compute_metrics(hard_rows, hard_predictions, best_state["threshold"], labels_config)
    torch.save(best_state, args.out / "best.pt")
    write_json(
        args.out / "metrics.json",
        {
            "input_mode": args.input_mode,
            "test": test_metrics,
            "hard_test": hard_metrics,
            "threshold": best_state["threshold"],
        },
    )
    write_json(
        args.out / "calibration.json",
        {
            "response_threshold": best_state["threshold"],
            "language_thresholds": best_state.get("language_thresholds"),
            "dev": best_state.get("dev_metrics"),
            "dev_gates": best_state.get("dev_gates"),
        },
    )
    write_json(args.out / "vocab.json", best_state["vocab"])
    write_jsonl(args.out / "test_predictions.jsonl", prediction_rows(test_rows, test_predictions))
    if hard_rows:
        write_jsonl(args.out / "hard_test_predictions.jsonl", prediction_rows(hard_rows, hard_predictions))
    return 0


class MultiQTDataset(Dataset):
    def __init__(
        self,
        rows: list[dict[str, Any]],
        vocab: dict[str, int],
        label_to_id: dict[str, int],
        audio_root: Path,
        max_tokens: int,
        max_frames: int,
    ) -> None:
        self.rows = rows
        self.vocab = vocab
        self.label_to_id = label_to_id
        self.audio_root = audio_root
        self.max_tokens = max_tokens
        self.max_frames = max_frames
        self.audio_cache: dict[str, torch.Tensor] = {}
        self.mel = torchaudio.transforms.MelSpectrogram(
            sample_rate=16000,
            n_fft=400,
            win_length=320,
            hop_length=160,
            n_mels=40,
        )

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, index: int) -> dict[str, torch.Tensor]:
        row = self.rows[index]
        audio_key = audio_cache_key(row, fallback=index)
        if audio_key not in self.audio_cache:
            self.audio_cache[audio_key] = load_logmel(row, self.audio_root, self.mel, self.max_frames)
        return {
            "text_tokens": torch.tensor(encode_text(text_for_row(row), self.vocab, self.max_tokens), dtype=torch.long),
            "audio_logmel": self.audio_cache[audio_key],
            "scalars": torch.tensor(scalars_for_row(row), dtype=torch.float32),
            "response_needed": torch.tensor(float(row["response_needed"]), dtype=torch.float32),
            "complete": torch.tensor(float(row["complete"]), dtype=torch.float32),
            "rhetorical": torch.tensor(float(row["label"] == "rhetorical"), dtype=torch.float32),
            "critical_negative": torch.tensor(float(row.get("critical_negative", False)), dtype=torch.float32),
            "label_id": torch.tensor(self.label_to_id[row["label"]], dtype=torch.long),
        }


def build_vocab(rows: list[dict[str, Any]], min_count: int, max_size: int) -> dict[str, int]:
    counts: dict[str, int] = {}
    for row in rows:
        for token in tokenize(text_for_row(row)):
            counts[token] = counts.get(token, 0) + 1
    vocab = {"<pad>": 0, "<unk>": 1}
    for token, count in sorted(counts.items(), key=lambda item: (-item[1], item[0])):
        if count < min_count:
            continue
        vocab[token] = len(vocab)
        if len(vocab) >= max_size:
            break
    return vocab


def audio_cache_key(row: dict[str, Any], fallback: int) -> str:
    if row.get("audio_feature_source") != "signal_proxy":
        return str(row.get("audio_feature_source") or "logmel") + ":" + str(row.get("audio_feature_path") or row.get("audio_path") or fallback)
    fields = [
        "start_ms",
        "end_ms",
        "rms",
        "peak",
        "audio_energy",
        "noise_floor",
        "partial_stability",
        "gap_count",
        "terminal_pause_ms",
        "is_clipping",
        "is_silence",
        "is_too_quiet",
    ]
    return "signal_proxy:" + "|".join(str(row.get(field, "")) for field in fields)


def audio_feature_sources(rows: list[dict[str, Any]]) -> list[str]:
    sources = {
        str(row.get("audio_feature_source") or "logmel")
        for row in rows
    }
    return sorted(sources)


def tokenize(text: str) -> list[str]:
    return TOKEN_RE.findall(text.lower())


def text_for_row(row: dict[str, Any]) -> str:
    return str(row.get("asr_transcript") or row.get("transcript") or "")


def encode_text(text: str, vocab: dict[str, int], max_tokens: int) -> list[int]:
    ids = [vocab.get(token, vocab["<unk>"]) for token in tokenize(text)[:max_tokens]]
    return ids + [vocab["<pad>"]] * (max_tokens - len(ids))


def load_logmel(
    row: dict[str, Any],
    audio_root: Path,
    mel: torchaudio.transforms.MelSpectrogram,
    max_frames: int,
) -> torch.Tensor:
    if row.get("audio_feature_source") == "signal_proxy":
        return proxy_logmel(row, max_frames)

    if row.get("audio_feature_path"):
        return load_materialized_logmel(row, audio_root, max_frames)

    audio_path = Path(str(row["audio_path"]))
    if not audio_path.is_absolute():
        audio_path = audio_root / audio_path
    waveform, sample_rate = torchaudio.load(audio_path)
    waveform = waveform.mean(dim=0, keepdim=True)
    if sample_rate != 16000:
        waveform = torchaudio.functional.resample(waveform, sample_rate, 16000)
    features = torch.log1p(mel(waveform)).squeeze(0)
    if features.shape[1] > max_frames:
        features = features[:, :max_frames]
    elif features.shape[1] < max_frames:
        pad = torch.zeros(features.shape[0], max_frames - features.shape[1])
        features = torch.cat([features, pad], dim=1)
    mean = features.mean()
    std = features.std().clamp_min(1e-4)
    return (features - mean) / std


def load_materialized_logmel(row: dict[str, Any], audio_root: Path, max_frames: int) -> torch.Tensor:
    feature_path = Path(str(row["audio_feature_path"]))
    if not feature_path.is_absolute():
        feature_path = audio_root / feature_path
    if not feature_path.exists():
        raise FileNotFoundError(f"audio feature file not found for {row.get('id')}: {feature_path}")
    if feature_path.suffix == ".pt":
        payload = torch.load(feature_path, map_location="cpu")
        features = payload if isinstance(payload, torch.Tensor) else torch.tensor(payload, dtype=torch.float32)
    else:
        features = torch.from_numpy(np.load(feature_path)).float()
    if features.ndim != 2:
        raise ValueError(f"audio feature must be 2D for {row.get('id')}: {feature_path}")
    if features.shape[0] != 40 and features.shape[1] == 40:
        features = features.transpose(0, 1)
    if features.shape[0] != 40:
        raise ValueError(f"audio feature must have 40 bands for {row.get('id')}: {feature_path}")
    if features.shape[1] > max_frames:
        features = features[:, :max_frames]
    elif features.shape[1] < max_frames:
        pad = torch.zeros(features.shape[0], max_frames - features.shape[1], dtype=features.dtype)
        features = torch.cat([features, pad], dim=1)
    if not torch.isfinite(features).all():
        raise ValueError(f"audio feature contains non-finite values for {row.get('id')}: {feature_path}")
    return features.contiguous()


def proxy_logmel(row: dict[str, Any], max_frames: int) -> torch.Tensor:
    frames = max(1, max_frames)
    duration_ms = max(0, int(row.get("end_ms", 0)) - int(row.get("start_ms", 0)))
    active_frames = min(frames, max(1, int((duration_ms / 1000.0) * 100)))
    rms = clamp_float(row.get("rms"), 0.0, 1.0, 0.018)
    peak = clamp_float(row.get("peak"), 0.0, 1.0, max(rms * 2, 0.03))
    energy = clamp_float(row.get("audio_energy"), 0.0, 1.0, rms)
    noise_floor = clamp_float(row.get("noise_floor"), 0.0, 1.0, 0.002)
    stability = clamp_float(row.get("partial_stability"), 0.0, 1.0, 1.0)
    gap_count = max(0, int(row.get("gap_count") or 0))
    terminal_pause_ms = max(0, int(row.get("terminal_pause_ms") or 0))
    is_silence = bool(row.get("is_silence", False))
    is_too_quiet = bool(row.get("is_too_quiet", False))
    is_clipping = bool(row.get("is_clipping", False))

    base_energy = 0.0 if is_silence else max(energy, rms * 0.85, peak * 0.25)
    if is_too_quiet:
        base_energy *= 0.35
    gap_penalty = max(0.2, 1.0 - min(gap_count, 8) * 0.08)
    pause_shape = min(1.0, terminal_pause_ms / 900.0)
    time_axis, band_axis = proxy_axes(frames)
    envelope = torch.zeros(frames)
    envelope[:active_frames] = torch.linspace(0.85, 1.0, active_frames)
    if active_frames < frames:
        envelope[active_frames:] = max(0.0, 0.45 - pause_shape * 0.3)
    modulation = 1.0 + 0.08 * torch.sin(time_axis * 17.0) + 0.04 * torch.cos(time_axis * 7.0)
    spectral_tilt = torch.exp(-band_axis * (1.5 + noise_floor * 5.0))
    features = spectral_tilt * envelope.unsqueeze(0) * modulation.unsqueeze(0) * max(base_energy * 30.0, 0.001)
    features += noise_floor * 2.0
    features *= gap_penalty * (0.65 + 0.35 * stability)
    if is_clipping:
        features[30:, :active_frames] += peak * 8.0
    features = torch.log1p(features)
    mean = features.mean()
    std = features.std().clamp_min(1e-4)
    return (features - mean) / std


@lru_cache(maxsize=16)
def proxy_axes(frames: int) -> tuple[torch.Tensor, torch.Tensor]:
    return torch.linspace(0, 1, frames), torch.linspace(0, 1, 40).unsqueeze(1)


def clamp_float(value: Any, minimum: float, maximum: float, default: float) -> float:
    if value is None:
        return default
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    if number != number:
        return default
    return min(max(number, minimum), maximum)


def scalars_for_row(row: dict[str, Any]) -> list[float]:
    duration = max(0, int(row["end_ms"]) - int(row["start_ms"])) / 1000.0
    language = str(row["language"])
    return [
        float(row.get("asr_confidence") if row.get("asr_confidence") is not None else 1.0),
        1.0 if row.get("is_partial") else 0.0,
        min(duration / 20.0, 1.0),
        *(1.0 if language == item else 0.0 for item in LANGUAGES),
    ]


def sample_weights(batch: dict[str, torch.Tensor], positive_weight: float, critical_negative_weight: float) -> torch.Tensor:
    positive = batch["response_needed"].float()
    critical_negative = batch["critical_negative"].float()
    return torch.ones_like(positive) + positive * max(0.0, positive_weight - 1.0) + critical_negative * max(0.0, critical_negative_weight - 1.0)


def weighted_mean(losses: torch.Tensor, weights: torch.Tensor) -> torch.Tensor:
    weighted = losses * weights
    return weighted.sum() / weights.sum().clamp_min(1e-6)


def clone_state_dict(model: nn.Module) -> dict[str, torch.Tensor]:
    return {
        key: value.detach().cpu().clone()
        for key, value in model.state_dict().items()
    }


def resolve_device(requested: str) -> torch.device:
    if requested == "mps":
        if not torch.backends.mps.is_available():
            raise SystemExit("MPS requested but not available")
        return torch.device("mps")
    if requested == "auto" and torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def batch_to_device(batch: dict[str, torch.Tensor], device: torch.device) -> dict[str, torch.Tensor]:
    if device.type == "cpu":
        return batch
    return {key: value.to(device) for key, value in batch.items()}


def predict(
    model: MultiQTConcatModel,
    dataset: MultiQTDataset,
    batch_size: int,
    device: torch.device | None = None,
) -> list[dict[str, float | bool]]:
    model.eval()
    output: list[dict[str, float | bool]] = []
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=False)
    device = device or torch.device("cpu")
    with torch.no_grad():
        for batch in loader:
            batch = batch_to_device(batch, device)
            started = time.perf_counter()
            response_logit, label_logits, complete_logit, rhetorical_logit = model(batch["text_tokens"], batch["audio_logmel"], batch["scalars"])
            elapsed_ms = (time.perf_counter() - started) * 1000.0
            scores = torch.sigmoid(response_logit).cpu().tolist()
            label_ids = torch.argmax(label_logits, dim=1).cpu().tolist()
            complete_scores = torch.sigmoid(complete_logit).cpu().tolist()
            rhetorical_scores = torch.sigmoid(rhetorical_logit).cpu().tolist()
            truths = batch["response_needed"].cpu().tolist()
            per_item_ms = safe_div(elapsed_ms, max(1, len(scores)))
            for score, label_id, complete_score, rhetorical_score, truth in zip(scores, label_ids, complete_scores, rhetorical_scores, truths):
                output.append(
                    {
                        "score": float(score),
                        "label_id": float(label_id),
                        "complete_score": float(complete_score),
                        "rhetorical_score": float(rhetorical_score),
                        "decision_ms": per_item_ms,
                        "truth": bool(truth),
                    }
                )
    return output


def prediction_rows(
    manifest_rows: list[dict[str, Any]],
    predictions: list[dict[str, float | bool]],
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for manifest, prediction in zip(manifest_rows, predictions):
        rows.append(
            {
                "id": manifest["id"],
                "score": prediction["score"],
                "label_id": prediction["label_id"],
                "complete_score": prediction["complete_score"],
                "rhetorical_score": prediction["rhetorical_score"],
                "decision_ms": prediction["decision_ms"],
            }
        )
    return rows


def tune_threshold(
    manifest_rows: list[dict[str, Any]],
    predictions: list[dict[str, float | bool]],
    labels_config: dict[str, Any],
    min_threshold: float = 0.50,
) -> tuple[float, dict[str, Any], dict[str, bool]]:
    floor = min(max(min_threshold, 0.05), 0.99)
    best_threshold = floor
    best_metrics: dict[str, Any] = {"precision": 0.0, "recall": 0.0, "critical_negative_false_positives": 0}
    best_gates: dict[str, bool] = {}
    best_score: tuple[float, ...] = (-1.0,)
    first_step = max(5, min(99, math.ceil(floor * 100)))
    for step in range(first_step, 100):
        threshold = step / 100.0
        metrics = compute_metrics(manifest_rows, predictions, threshold, labels_config)
        gates = calibration_gates(metrics)
        score = calibration_score(metrics, gates, threshold)
        if score > best_score:
            best_score = score
            best_threshold = threshold
            best_metrics = metrics
            best_gates = gates
    return best_threshold, best_metrics, best_gates


def tune_thresholds_by_group(
    manifest_rows: list[dict[str, Any]],
    predictions: list[dict[str, float | bool]],
    labels_config: dict[str, Any],
    key: str,
    expected_values: list[str],
    min_threshold: float = 0.50,
) -> dict[str, float]:
    thresholds: dict[str, float] = {}
    paired = list(zip(manifest_rows, predictions))
    for value in expected_values:
        group_pairs = [(row, prediction) for row, prediction in paired if str(row.get(key, "")) == value]
        if not group_pairs:
            continue
        group_rows = [row for row, _ in group_pairs]
        group_predictions = [prediction for _, prediction in group_pairs]
        threshold, _, _ = tune_threshold(group_rows, group_predictions, labels_config, min_threshold=min_threshold)
        thresholds[value] = threshold
    return thresholds


def compute_metrics(
    manifest_rows: list[dict[str, Any]],
    predictions: list[dict[str, float | bool]],
    threshold: float,
    labels_config: dict[str, Any],
) -> dict[str, Any]:
    predicted_by_id = {
        str(manifest["id"]): float(prediction["score"]) >= threshold
        for manifest, prediction in zip(manifest_rows, predictions)
    }
    return binary_metrics(manifest_rows, predicted_by_id, labels_config)


def calibration_gates(metrics: dict[str, Any]) -> dict[str, bool]:
    gates: dict[str, bool] = {
        "precision_gte_0_995": float(metrics["precision"]) >= 0.995,
        "recall_gte_0_970": float(metrics["recall"]) >= 0.970,
        "critical_fp_zero": int(metrics["critical_negative_false_positives"]) == 0,
    }
    for language, language_metrics in metrics.get("by_language", {}).items():
        gates[f"{language}_precision_gte_0_990"] = float(language_metrics["precision"]) >= 0.990
        gates[f"{language}_recall_gte_0_950"] = float(language_metrics["recall"]) >= 0.950
        gates[f"{language}_critical_fp_zero"] = int(language_metrics["critical_negative_false_positives"]) == 0
    for label, label_metrics in metrics.get("by_label", {}).items():
        gates[f"{label}_critical_fp_zero"] = int(label_metrics["critical_negative_false_positives"]) == 0
    return gates


def calibration_score(metrics: dict[str, Any], gates: dict[str, bool], threshold: float) -> tuple[float, ...]:
    language_metrics = list(metrics.get("by_language", {}).values())
    min_language_precision = min((float(item["precision"]) for item in language_metrics), default=0.0)
    min_language_recall = min((float(item["recall"]) for item in language_metrics), default=0.0)
    return (
        1.0 if all(gates.values()) else 0.0,
        1.0 if int(metrics["critical_negative_false_positives"]) == 0 else 0.0,
        float(metrics["precision"]),
        min_language_precision,
        float(metrics["recall"]),
        min_language_recall,
        threshold,
    )


if __name__ == "__main__":
    raise SystemExit(main())
