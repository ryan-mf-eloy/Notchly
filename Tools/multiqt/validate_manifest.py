#!/usr/bin/env python3
"""Validate MultiQT JSONL manifests without persisting or printing raw audio."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from common import DEFAULT_LABELS_PATH, load_labels, read_jsonl, truth_for_row


REQUIRED_FIELDS = {
    "id": str,
    "language": str,
    "audio_path": str,
    "sample_rate": int,
    "transcript": str,
    "asr_transcript": str,
    "start_ms": int,
    "end_ms": int,
    "is_partial": bool,
    "label": str,
    "response_needed": bool,
    "critical_negative": bool,
    "complete": bool,
    "question_span": list,
    "source": str,
    "split": str,
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifests", nargs="+", type=Path)
    parser.add_argument("--labels", type=Path, default=DEFAULT_LABELS_PATH)
    parser.add_argument("--audio-root", type=Path, default=None)
    parser.add_argument("--check-audio", action="store_true")
    parser.add_argument("--max-errors", type=int, default=50)
    args = parser.parse_args()

    labels = load_labels(args.labels)
    allowed_languages = set(labels["languages"])
    allowed_labels = (
        set(labels["positive_labels"])
        | set(labels["critical_negative_labels"])
        | set(labels["noncritical_negative_labels"])
    )
    allowed_splits = {"train", "dev", "test", "hard_test"}
    allowed_sources = {"manual", "synthetic", "shadow_redacted", "public"}
    allowed_audio_feature_sources = {"logmel", "signal_proxy", "synthetic_logmel"}

    errors: list[str] = []
    summary: dict[str, Any] = {
        "rows": 0,
        "positive": 0,
        "negative": 0,
        "by_language": {},
        "by_label": {},
        "by_split": {},
    }

    seen_ids: set[str] = set()
    for manifest in args.manifests:
        rows = read_jsonl(manifest)
        for index, row in enumerate(rows, start=1):
            location = f"{manifest}:{index}"
            validate_row(
                row,
                location,
                labels,
                allowed_languages,
                allowed_labels,
                allowed_sources,
                allowed_splits,
                allowed_audio_feature_sources,
                args.audio_root or manifest.parent,
                args.check_audio,
                errors,
                args.max_errors,
            )
            row_id = str(row.get("id", ""))
            if row_id in seen_ids:
                add_error(errors, args.max_errors, f"{location}: duplicate id {row_id}")
            seen_ids.add(row_id)

            summary["rows"] += 1
            if truth_for_row(row, labels):
                summary["positive"] += 1
            else:
                summary["negative"] += 1
            increment(summary["by_language"], str(row.get("language", "missing")))
            increment(summary["by_label"], str(row.get("label", "missing")))
            increment(summary["by_split"], str(row.get("split", "missing")))

    payload = {"valid": not errors, "summary": summary, "errors": errors}
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0 if not errors else 1


def validate_row(
    row: dict[str, Any],
    location: str,
    labels: dict[str, Any],
    allowed_languages: set[str],
    allowed_labels: set[str],
    allowed_sources: set[str],
    allowed_splits: set[str],
    allowed_audio_feature_sources: set[str],
    audio_root: Path,
    check_audio: bool,
    errors: list[str],
    max_errors: int,
) -> None:
    for field, expected_type in REQUIRED_FIELDS.items():
        if field not in row:
            add_error(errors, max_errors, f"{location}: missing {field}")
            continue
        value = row[field]
        if expected_type is bool:
            valid_type = type(value) is bool
        else:
            valid_type = isinstance(value, expected_type)
        if not valid_type:
            add_error(errors, max_errors, f"{location}: {field} has invalid type")

    language = row.get("language")
    label = row.get("label")
    source = row.get("source")
    split = row.get("split")
    if language not in allowed_languages:
        add_error(errors, max_errors, f"{location}: unsupported language {language}")
    if label not in allowed_labels:
        add_error(errors, max_errors, f"{location}: unsupported label {label}")
    if source not in allowed_sources:
        add_error(errors, max_errors, f"{location}: unsupported source {source}")
    if split not in allowed_splits:
        add_error(errors, max_errors, f"{location}: unsupported split {split}")

    audio_feature_source = row.get("audio_feature_source")
    if audio_feature_source is not None and audio_feature_source not in allowed_audio_feature_sources:
        add_error(
            errors,
            max_errors,
            f"{location}: unsupported audio_feature_source {audio_feature_source}",
        )

    audio_feature_path = row.get("audio_feature_path")
    if audio_feature_path is not None and not isinstance(audio_feature_path, str):
        add_error(errors, max_errors, f"{location}: audio_feature_path has invalid type")

    start_ms = row.get("start_ms", 0)
    end_ms = row.get("end_ms", 0)
    if isinstance(start_ms, int) and isinstance(end_ms, int) and end_ms < start_ms:
        add_error(errors, max_errors, f"{location}: end_ms must be >= start_ms")
    sample_rate = row.get("sample_rate")
    if isinstance(sample_rate, int) and sample_rate < 8000:
        add_error(errors, max_errors, f"{location}: sample_rate below 8000")

    response_needed = row.get("response_needed")
    positive = label in set(labels["positive_labels"])
    if isinstance(response_needed, bool) and response_needed != positive:
        add_error(errors, max_errors, f"{location}: response_needed does not match label polarity")

    critical = row.get("critical_negative")
    critical_label = label in set(labels["critical_negative_labels"])
    if isinstance(critical, bool) and critical != critical_label:
        add_error(errors, max_errors, f"{location}: critical_negative does not match label family")

    span = row.get("question_span")
    transcript = str(row.get("asr_transcript") or row.get("transcript") or "")
    if isinstance(span, list) and len(span) == 2 and all(isinstance(value, int) for value in span):
        if span[0] > span[1]:
            add_error(errors, max_errors, f"{location}: question_span start must be <= end")
        if span[1] > len(transcript):
            add_error(errors, max_errors, f"{location}: question_span exceeds transcript length")

    if check_audio:
        audio_path = row.get("audio_path")
        if isinstance(audio_path, str):
            resolved = Path(audio_path)
            if not resolved.is_absolute():
                resolved = audio_root / resolved
            if not resolved.exists():
                add_error(errors, max_errors, f"{location}: audio file not found")
        if isinstance(audio_feature_path, str):
            resolved = Path(audio_feature_path)
            if not resolved.is_absolute():
                resolved = audio_root / resolved
            if not resolved.exists():
                add_error(errors, max_errors, f"{location}: audio feature file not found")


def add_error(errors: list[str], max_errors: int, message: str) -> None:
    if len(errors) < max_errors:
        errors.append(message)


def increment(bucket: dict[str, int], key: str) -> None:
    bucket[key] = bucket.get(key, 0) + 1


if __name__ == "__main__":
    raise SystemExit(main())
