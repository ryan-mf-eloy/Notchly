#!/usr/bin/env python3
"""Convert privacy-redacted Notchly QA shadow logs into a MultiQT manifest.

Input rows must contain redacted text only. Raw transcripts, raw snippets, and
audio paths are rejected so the resulting manifest can be used for active
learning without persisting sensitive meeting content or audio.
"""

from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path
from typing import Any

from common import DEFAULT_LABELS_PATH, load_labels, read_jsonl, write_json, write_jsonl


FORBIDDEN_RAW_FIELDS = {
    "raw_text",
    "rawText",
    "rawTranscript",
    "raw_transcript",
    "transcript",
    "snippet",
    "rawSnippet",
    "audio_path",
    "raw_audio_path",
    "audioBase64",
    "audio_base64",
}
SECRET_PATTERNS = [
    re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE),
    re.compile(r"\b(?:\+?\d[\s().-]?){8,}\d\b"),
    re.compile(r"\b(?:sk|pk|rk|ghp|gho|ghu|github_pat)_[A-Za-z0-9_=-]{12,}\b"),
    re.compile(r"\b[A-Za-z0-9_=-]{32,}\b"),
]
LABEL_ALIASES = {
    "title": "title_noise",
    "answerable": "answerable_question",
    "question": "answerable_question",
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="JSONL file with redacted shadow rows.")
    parser.add_argument("--out", required=True, type=Path, help="Output MultiQT JSONL manifest.")
    parser.add_argument("--labels", type=Path, default=DEFAULT_LABELS_PATH)
    parser.add_argument("--default-split", choices=["train", "dev", "test", "hard_test", "hash"], default="hash")
    parser.add_argument("--max-errors", type=int, default=50)
    args = parser.parse_args()

    labels = load_labels(args.labels)
    rows = read_jsonl(args.input)
    manifest: list[dict[str, Any]] = []
    errors: list[str] = []
    for index, row in enumerate(rows, start=1):
        try:
            manifest.append(convert_row(row, labels, args.default_split))
        except ValueError as error:
            if len(errors) < args.max_errors:
                errors.append(f"{args.input}:{index}: {error}")

    report = {
        "input_rows": len(rows),
        "output_rows": len(manifest),
        "rejected_rows": len(rows) - len(manifest),
        "errors": errors,
        "privacy": {
            "raw_audio_persisted": False,
            "raw_text_allowed": False,
            "source": "shadow_redacted",
        },
    }
    write_json(args.out.with_suffix(".report.json"), report)
    if errors:
        print_report(report)
        return 1
    write_jsonl(args.out, manifest)
    print_report(report)
    return 0


def convert_row(row: dict[str, Any], labels: dict[str, Any], default_split: str) -> dict[str, Any]:
    forbidden = sorted(field for field in FORBIDDEN_RAW_FIELDS if field in row and row.get(field))
    if forbidden:
        raise ValueError(f"raw or audio fields are not allowed: {', '.join(forbidden)}")
    if not is_redacted(row):
        raise ValueError("row must declare redacted=true or privacy.redacted=true")

    text = str(row.get("redacted_text") or row.get("asr_text_redacted") or row.get("text_redacted") or "").strip()
    if not text:
        raise ValueError("missing redacted_text/asr_text_redacted")
    if looks_sensitive(text):
        raise ValueError("redacted text still appears to contain sensitive identifiers")

    language = str(row.get("language") or "unknown")
    if language not in set(labels["languages"]):
        raise ValueError(f"unsupported language {language}")
    label = normalize_label(str(row.get("label") or ""), labels)
    positive = label in set(labels["positive_labels"])
    critical_negative = label in set(labels["critical_negative_labels"])
    split = split_for_row(row, default_split)
    start_ms = nonnegative_int(row.get("start_ms"), 0)
    end_ms = nonnegative_int(row.get("end_ms"), start_ms + estimate_duration_ms(text))
    if end_ms < start_ms:
        raise ValueError("end_ms must be >= start_ms")

    output = {
        "id": str(row.get("id") or stable_id(text, language, label)),
        "language": language,
        "audio_path": "shadow_redacted/no_raw_audio.wav",
        "sample_rate": 16000,
        "transcript": text,
        "asr_transcript": text,
        "start_ms": start_ms,
        "end_ms": end_ms,
        "is_partial": bool(row.get("is_partial", row.get("isPartial", False))),
        "asr_confidence": clamp_float(row.get("asr_confidence"), 0, 1, 0.9),
        "speaker_role": str(row.get("speaker_role") or "shadow_redacted"),
        "label": label,
        "response_needed": positive,
        "candidate_detection": bool(row.get("candidate_detection", row.get("candidateDetection", positive))),
        "surface_miss": bool(row.get(
            "surface_miss",
            row.get("surfaceMiss", str(row.get("discoverySource", "")) in {"multiqtRescue", "shadowRescue"}),
        )),
        "critical_negative": critical_negative,
        "complete": bool(row.get("complete", label != "fragment" and not bool(row.get("is_partial", False)))),
        "question_span": question_span(row, text),
        "source": "shadow_redacted",
        "split": split,
        "audio_feature_source": "signal_proxy",
    }
    signal = row.get("signal") if isinstance(row.get("signal"), dict) else row
    copy_signal(output, signal)
    return output


def is_redacted(row: dict[str, Any]) -> bool:
    privacy = row.get("privacy")
    if isinstance(privacy, dict) and privacy.get("redacted") is True:
        return True
    return row.get("redacted") is True


def normalize_label(label: str, labels: dict[str, Any]) -> str:
    normalized = LABEL_ALIASES.get(label, label)
    allowed = set(labels["positive_labels"]) | set(labels["critical_negative_labels"]) | set(labels["noncritical_negative_labels"])
    if normalized not in allowed:
        raise ValueError(f"unsupported label {label}")
    return normalized


def looks_sensitive(text: str) -> bool:
    return any(pattern.search(text) for pattern in SECRET_PATTERNS)


def split_for_row(row: dict[str, Any], default_split: str) -> str:
    split = row.get("split")
    if split in {"train", "dev", "test", "hard_test"}:
        return str(split)
    if default_split != "hash":
        return default_split
    bucket = int(hashlib.sha256(str(row.get("id") or row).encode("utf-8")).hexdigest()[:8], 16) % 100
    if bucket < 70:
        return "train"
    if bucket < 82:
        return "dev"
    if bucket < 94:
        return "test"
    return "hard_test"


def stable_id(text: str, language: str, label: str) -> str:
    digest = hashlib.sha256(f"{language}\0{label}\0{text}".encode("utf-8")).hexdigest()[:16]
    return f"shadow-{digest}"


def estimate_duration_ms(text: str) -> int:
    return min(max(int(max(1, len(text)) * 55), 650), 20000)


def nonnegative_int(value: Any, default: int) -> int:
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return default


def question_span(row: dict[str, Any], text: str) -> list[int]:
    span = row.get("question_span")
    if isinstance(span, list) and len(span) == 2 and all(isinstance(item, int) for item in span):
        start = max(0, min(span[0], len(text)))
        end = max(start, min(span[1], len(text)))
        return [start, end]
    return [0, len(text)]


def copy_signal(output: dict[str, Any], signal: dict[str, Any]) -> None:
    numeric_fields = ["rms", "peak", "audio_energy", "noise_floor", "partial_stability"]
    int_fields = ["gap_count", "terminal_pause_ms"]
    bool_fields = ["is_clipping", "is_silence", "is_too_quiet"]
    for field in numeric_fields:
        if field in signal:
            output[field] = clamp_float(signal.get(field), 0, 1, None)
    for field in int_fields:
        if field in signal:
            output[field] = nonnegative_int(signal.get(field), 0)
    for field in bool_fields:
        if field in signal:
            output[field] = bool(signal.get(field))


def clamp_float(value: Any, minimum: float, maximum: float, default: float | None) -> float | None:
    if value is None:
        return default
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    if number != number:
        return default
    return min(max(number, minimum), maximum)


def print_report(report: dict[str, Any]) -> None:
    import json

    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    raise SystemExit(main())
