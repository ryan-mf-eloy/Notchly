#!/usr/bin/env python3
"""Build a MultiQT manifest from Notchly's multilingual gold fixture.

Audio generation is optional and local. When enabled, this script uses macOS
`say` to synthesize deterministic seed audio for bootstrapping only; this does
not replace real consented meeting audio for the final gate dataset.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import subprocess
from pathlib import Path
from typing import Any

from common import read_jsonl, write_jsonl


DEFAULT_QA_FIXTURE = Path("NotchCopilotTests/Fixtures/qa_intent_gold.jsonl")
DEFAULT_COPILOT_FIXTURE = Path("NotchCopilotTests/Fixtures/copilot_intent_gold.jsonl")
LABEL_MAP = {
    "answerable_question": "answerable_question",
    "action_request": "action_request",
    "technical_explanation": "technical_explanation",
    "calculation": "answerable_question",
    "conversion": "answerable_question",
    "news": "action_request",
    "web": "action_request",
    "reminder": "action_request",
    "memory": "action_request",
    "statement": "statement",
    "small_talk": "small_talk",
    "operational_check": "operational_check",
    "rhetorical": "rhetorical",
    "reported_question": "reported_question",
    "self_answered": "self_answered",
    "fragment": "fragment",
    "title": "title_noise",
}
POSITIVE_LABELS = {
    "answerable_question",
    "action_request",
    "status",
    "risk",
    "technical_decision",
    "technical_explanation",
    "deadline",
    "ownership",
    "follow_up",
    "business",
}
CRITICAL_NEGATIVE_LABELS = {
    "small_talk",
    "operational_check",
    "rhetorical",
    "reported_question",
    "self_answered",
    "fragment",
    "title_noise",
}
VOICE_BY_LANGUAGE = {
    "pt-BR": "Luciana",
    "en-US": "Samantha",
    "es-ES": "Monica",
    "ja-JP": "Kyoko",
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--fixture",
        dest="fixtures",
        type=Path,
        action="append",
        default=None,
        help="Gold JSONL fixture to convert. May be passed more than once.",
    )
    parser.add_argument(
        "--include-copilot-fixture",
        action="store_true",
        help="Also include NotchCopilotTests/Fixtures/copilot_intent_gold.jsonl.",
    )
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument("--generate-audio", action="store_true")
    parser.add_argument(
        "--audio-feature-source",
        choices=["none", "signal_proxy"],
        default="none",
        help="Use signal_proxy to make the manifest trainable without persisted audio files.",
    )
    parser.add_argument("--max-rows", type=int, default=0)
    parser.add_argument("--sample-rate", type=int, default=16000)
    parser.add_argument("--jobs", type=int, default=1, help="Concurrent local `say` jobs for synthetic audio generation.")
    args = parser.parse_args()
    if args.generate_audio and args.audio_feature_source == "signal_proxy":
        raise SystemExit("--generate-audio and --audio-feature-source signal_proxy are mutually exclusive")

    fixture_paths = args.fixtures or [DEFAULT_QA_FIXTURE]
    if args.include_copilot_fixture and DEFAULT_COPILOT_FIXTURE not in fixture_paths:
        fixture_paths.append(DEFAULT_COPILOT_FIXTURE)
    source_rows = load_fixture_rows(fixture_paths, max_rows=args.max_rows)

    manifests: dict[str, list[dict[str, Any]]] = {"train": [], "dev": [], "test": [], "hard_test": []}
    audio_dir = args.out_dir / "audio"
    if args.generate_audio:
        audio_dir.mkdir(parents=True, exist_ok=True)

    pending_audio: list[tuple[str, str, Path, int]] = []
    prefix_ids = len(fixture_paths) > 1
    for fixture_path, source in source_rows:
        text = str(source["text"])
        label = LABEL_MAP.get(str(source["label"]), str(source["label"]))
        row_id = row_id_for(source, fixture_path, prefix_ids=prefix_ids)
        split = split_for_id(row_id)
        audio_path = f"audio/{row_id}.aiff"
        row = {
            "id": row_id,
            "language": source["language"],
            "audio_path": audio_path,
            "sample_rate": args.sample_rate,
            "transcript": text,
            "asr_transcript": text,
            "start_ms": 0,
            "end_ms": estimate_duration_ms(text),
            "is_partial": bool(source.get("isPartial", False)),
            "asr_confidence": 0.92,
            "speaker_role": "synthetic",
            "label": label,
            "response_needed": bool(source.get("responseNeeded", label in POSITIVE_LABELS)),
            "critical_negative": label in CRITICAL_NEGATIVE_LABELS,
            "complete": label != "fragment",
            "question_span": [0, len(text)],
            "source": "synthetic",
            "split": split,
        }
        if args.audio_feature_source == "signal_proxy":
            row["audio_path"] = f"signal_proxy/{row_id}.wav"
            row["audio_feature_source"] = "signal_proxy"
            attach_signal_proxy(row)
        if args.generate_audio:
            pending_audio.append((text, source["language"], audio_dir / f"{row_id}.aiff", args.sample_rate))
        manifests[split].append(row)

    if pending_audio:
        synthesize_audio_batch(pending_audio, jobs=max(1, args.jobs))

    args.out_dir.mkdir(parents=True, exist_ok=True)
    for split, rows in manifests.items():
        write_jsonl(args.out_dir / f"{split}.jsonl", rows)
    return 0


def load_fixture_rows(fixture_paths: list[Path], max_rows: int) -> list[tuple[Path, dict[str, Any]]]:
    rows: list[tuple[Path, dict[str, Any]]] = []
    for fixture_path in fixture_paths:
        for source in read_jsonl(fixture_path):
            rows.append((fixture_path, source))
            if max_rows > 0 and len(rows) >= max_rows:
                return rows
    return rows


def row_id_for(source: dict[str, Any], fixture_path: Path, prefix_ids: bool) -> str:
    source_id = str(source["id"])
    if not prefix_ids:
        return source_id
    fixture_prefix = "".join(character if character.isalnum() else "-" for character in fixture_path.stem)
    return f"{fixture_prefix}__{source_id}"


def synthesize_audio_batch(items: list[tuple[str, str, Path, int]], jobs: int) -> None:
    if jobs <= 1:
        for text, language, output, sample_rate in items:
            synthesize_audio(text, language, output, sample_rate)
        return

    with ThreadPoolExecutor(max_workers=jobs) as executor:
        futures = [
            executor.submit(synthesize_audio, text, language, output, sample_rate)
            for text, language, output, sample_rate in items
        ]
        for future in as_completed(futures):
            future.result()


def split_for_id(row_id: str) -> str:
    bucket = int(hashlib.sha256(row_id.encode("utf-8")).hexdigest()[:8], 16) % 100
    if bucket < 72:
        return "train"
    if bucket < 84:
        return "dev"
    if bucket < 94:
        return "test"
    return "hard_test"


def estimate_duration_ms(text: str) -> int:
    chars = max(1, len(text))
    return min(max(int(chars * 55), 700), 18000)


def attach_signal_proxy(row: dict[str, Any]) -> None:
    duration_ms = max(0, int(row["end_ms"]) - int(row["start_ms"]))
    token_count = max(1, len(str(row["asr_transcript"]).split()))
    duration_factor = min(1.0, duration_ms / 8000.0)
    token_factor = min(1.0, token_count / 28.0)
    is_partial = bool(row.get("is_partial", False))
    row["rms"] = round(0.016 + duration_factor * 0.010 + token_factor * 0.004, 4)
    row["peak"] = round(min(0.18, row["rms"] * 4.2), 4)
    row["audio_energy"] = round(min(0.18, row["rms"] * (1.05 + token_factor * 0.25)), 4)
    row["noise_floor"] = 0.003
    row["partial_stability"] = 0.38 if is_partial else 1.0
    row["terminal_pause_ms"] = 90 if is_partial else min(900, max(260, int(duration_ms * 0.10)))
    row["gap_count"] = 1 if is_partial else 0
    row["is_clipping"] = False
    row["is_silence"] = False
    row["is_too_quiet"] = False


def synthesize_audio(text: str, language: str, output: Path, sample_rate: int) -> None:
    if output.exists() and output.stat().st_size > 0:
        return
    if output.exists():
        output.unlink()
    voice = VOICE_BY_LANGUAGE.get(language)
    # `say --data-format` support varies across macOS voices. Let `say` choose
    # the native AIFF format and resample during training.
    base = ["say", "-o", str(output)]
    command = [*base, "-v", voice, text] if voice else [*base, text]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode == 0:
        return
    fallback = subprocess.run([*base, text], capture_output=True, text=True, check=False)
    if fallback.returncode != 0:
        raise RuntimeError(f"say failed for {output.name}: {fallback.stderr.strip()}")


if __name__ == "__main__":
    raise SystemExit(main())
