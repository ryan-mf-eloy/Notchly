#!/usr/bin/env python3
"""Train the Notchly MultiQT audio+text classifier."""

from __future__ import annotations

import argparse
import json
import random
import re
import time
from pathlib import Path
from typing import Any

from common import DEFAULT_LABELS_PATH, load_labels, read_jsonl, safe_div, write_json, write_jsonl

try:
    import torch
    import torchaudio
    from torch import nn
    from torch.utils.data import DataLoader, Dataset
except ImportError as error:  # pragma: no cover - executed only on training machines.
    raise SystemExit(
        "Missing training dependencies. Install with: "
        "python3 -m pip install -r Tools/multiqt/requirements.txt"
    ) from error

from model import MODEL_INPUT_MODES, MultiQTConcatModel


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
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    random.seed(args.seed)
    torch.manual_seed(args.seed)

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
    )
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate, weight_decay=0.01)
    response_loss = nn.BCEWithLogitsLoss()
    label_loss = nn.CrossEntropyLoss()
    binary_loss = nn.BCEWithLogitsLoss()

    best_dev: tuple[float, float, float, float] = (-1.0, -1.0, -1.0, -1.0)
    best_state: dict[str, Any] | None = None
    args.out.mkdir(parents=True, exist_ok=True)

    for epoch in range(1, args.epochs + 1):
        model.train()
        total_loss = 0.0
        loader = DataLoader(train_data, batch_size=args.batch_size, shuffle=True)
        for batch in loader:
            optimizer.zero_grad(set_to_none=True)
            response_logit, label_logits, complete_logit, rhetorical_logit = model(
                batch["text_tokens"],
                batch["audio_logmel"],
                batch["scalars"],
            )
            loss = (
                response_loss(response_logit, batch["response_needed"])
                + 0.45 * label_loss(label_logits, batch["label_id"])
                + 0.20 * binary_loss(complete_logit, batch["complete"])
                + 0.20 * binary_loss(rhetorical_logit, batch["rhetorical"])
            )
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            total_loss += float(loss.detach().cpu())

        dev_predictions = predict(model, dev_data, args.batch_size)
        threshold, dev_metrics = tune_threshold(dev_predictions)
        gate_bonus = 1.0 if dev_metrics["precision"] >= 0.995 and dev_metrics["recall"] >= 0.970 else 0.0
        score = (gate_bonus, dev_metrics["precision"], dev_metrics["recall"], threshold)
        print(
            json.dumps(
                {
                    "epoch": epoch,
                    "loss": safe_div(total_loss, max(1, len(loader))),
                    "threshold": threshold,
                    "dev": dev_metrics,
                },
                sort_keys=True,
            )
        )
        if score > best_dev:
            best_dev = score
            best_state = {
                "model_state": model.state_dict(),
                "vocab": vocab,
                "labels": label_names,
                "threshold": threshold,
                "config": {
                    "max_tokens": args.max_tokens,
                    "max_frames": args.max_frames,
                    "scalar_count": 7,
                    "input_mode": args.input_mode,
                },
            }

    if best_state is None:
        raise SystemExit("Training produced no checkpoint")

    model.load_state_dict(best_state["model_state"])
    test_predictions = predict(model, test_data, args.batch_size)
    test_metrics = compute_metrics(test_predictions, best_state["threshold"])
    hard_metrics = None
    hard_predictions: list[dict[str, float | bool]] = []
    if hard_data is not None:
        hard_predictions = predict(model, hard_data, args.batch_size)
        hard_metrics = compute_metrics(hard_predictions, best_state["threshold"])
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
    write_json(args.out / "calibration.json", {"response_threshold": best_state["threshold"]})
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
        audio_key = str(row.get("audio_feature_path") or row.get("audio_path") or index)
        if audio_key not in self.audio_cache:
            self.audio_cache[audio_key] = load_logmel(row, self.audio_root, self.mel, self.max_frames)
        return {
            "text_tokens": torch.tensor(encode_text(text_for_row(row), self.vocab, self.max_tokens), dtype=torch.long),
            "audio_logmel": self.audio_cache[audio_key],
            "scalars": torch.tensor(scalars_for_row(row), dtype=torch.float32),
            "response_needed": torch.tensor(float(row["response_needed"]), dtype=torch.float32),
            "complete": torch.tensor(float(row["complete"]), dtype=torch.float32),
            "rhetorical": torch.tensor(float(row["label"] == "rhetorical"), dtype=torch.float32),
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


def scalars_for_row(row: dict[str, Any]) -> list[float]:
    duration = max(0, int(row["end_ms"]) - int(row["start_ms"])) / 1000.0
    language = str(row["language"])
    return [
        float(row.get("asr_confidence") if row.get("asr_confidence") is not None else 1.0),
        1.0 if row.get("is_partial") else 0.0,
        min(duration / 20.0, 1.0),
        *(1.0 if language == item else 0.0 for item in LANGUAGES),
    ]


def predict(model: MultiQTConcatModel, dataset: MultiQTDataset, batch_size: int) -> list[dict[str, float | bool]]:
    model.eval()
    output: list[dict[str, float | bool]] = []
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=False)
    with torch.no_grad():
        for batch in loader:
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


def tune_threshold(predictions: list[dict[str, float | bool]]) -> tuple[float, dict[str, float]]:
    best_threshold = 0.5
    best_metrics: dict[str, float] = {"precision": 0.0, "recall": 0.0}
    best_score: tuple[float, float, float, float] = (-1.0, -1.0, -1.0, -1.0)
    for step in range(5, 100):
        threshold = step / 100.0
        metrics = compute_metrics(predictions, threshold)
        gate_bonus = 1.0 if metrics["precision"] >= 0.995 and metrics["recall"] >= 0.970 else 0.0
        score = (gate_bonus, metrics["precision"], metrics["recall"], threshold)
        if score > best_score:
            best_score = score
            best_threshold = threshold
            best_metrics = metrics
    return best_threshold, best_metrics


def compute_metrics(predictions: list[dict[str, float | bool]], threshold: float) -> dict[str, float]:
    tp = fp = fn = tn = 0
    for row in predictions:
        predicted = float(row["score"]) >= threshold
        truth = bool(row["truth"])
        if predicted and truth:
            tp += 1
        elif predicted and not truth:
            fp += 1
        elif not predicted and truth:
            fn += 1
        else:
            tn += 1
    return {
        "tp": float(tp),
        "fp": float(fp),
        "fn": float(fn),
        "tn": float(tn),
        "precision": safe_div(tp, tp + fp),
        "recall": safe_div(tp, tp + fn),
    }


if __name__ == "__main__":
    raise SystemExit(main())
