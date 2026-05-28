#!/usr/bin/env python3
"""Harden MultiQT manifests with deterministic ASR and intent stress cases.

The goal is not to manufacture final production evidence. It is to make the
bootstrap training set less brittle by adding privacy-safe, reproducible rows
for the exact failure modes that matter in realtime meetings: unstable partials,
punctuation-free ASR, filler prefixes, reported questions, and self-answered
questions.
"""

from __future__ import annotations

import argparse
from collections import Counter
import copy
import hashlib
import json
import random
from pathlib import Path
import re
from typing import Any, Iterable

from common import read_jsonl, write_json, write_jsonl


SPLITS = ("train", "dev", "test", "hard_test")
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
FILLER_PREFIXES = {
    "pt-BR": ["entao uma duvida", "rapido uma pergunta", "so para entender"],
    "en-US": ["quick question", "just to understand", "one thing"],
    "es-ES": ["una duda rapida", "solo para entender", "una pregunta"],
    "ja-JP": ["確認ですが", "一つ質問です", "念のため"],
}
REPORTED_TEMPLATES = {
    "pt-BR": "perguntaram se {text} mas isso ja foi respondido",
    "en-US": "someone asked whether {text} but we already answered it",
    "es-ES": "preguntaron si {text} pero ya lo respondimos",
    "ja-JP": "{text} と聞かれましたが、もう回答しました",
}
SELF_ANSWERED_TEMPLATES = {
    "pt-BR": "{text} na verdade deixa ja encontrei a resposta",
    "en-US": "{text} actually never mind I found the answer",
    "es-ES": "{text} en realidad ya encontre la respuesta",
    "ja-JP": "{text} やっぱりもう分かりました",
}
TOKEN_RE = re.compile(r"\S+")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", required=True, type=Path)
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--augment-eval", action="store_true", help="Also add stress rows to dev/test/hard_test.")
    parser.add_argument("--train-asr-variants", type=int, default=2)
    parser.add_argument("--eval-asr-variants", type=int, default=1)
    args = parser.parse_args()

    rng = random.Random(args.seed)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    report: dict[str, Any] = {
        "input_dir": str(args.input_dir),
        "seed": args.seed,
        "augment_eval": args.augment_eval,
        "splits": {},
    }

    for split in SPLITS:
        input_path = args.input_dir / f"{split}.jsonl"
        rows = read_jsonl(input_path)
        augmented = list(rows)
        variants_per_row = args.train_asr_variants if split == "train" else args.eval_asr_variants
        if split == "train" or args.augment_eval:
            augmented.extend(augment_rows(rows, split=split, variants_per_row=variants_per_row, rng=rng))
        write_jsonl(args.out_dir / f"{split}.jsonl", augmented)
        report["splits"][split] = split_report(augmented)

    write_json(args.out_dir / "augmentation_report.json", report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


def augment_rows(
    rows: list[dict[str, Any]],
    split: str,
    variants_per_row: int,
    rng: random.Random,
) -> Iterable[dict[str, Any]]:
    for row in rows:
        text = text_for(row)
        label = str(row["label"])
        positive = bool(row.get("response_needed", label in POSITIVE_LABELS))
        language = str(row["language"])

        candidates: list[tuple[str, dict[str, Any]]] = []
        no_punctuation = strip_punctuation(text)
        if no_punctuation != text:
            candidates.append(("asr_no_punctuation", mutate_asr(row, no_punctuation)))

        lower_noise = remove_accents(strip_punctuation(text)).lower()
        if lower_noise != no_punctuation.lower():
            candidates.append(("asr_ascii_lower", mutate_asr(row, lower_noise, confidence_delta=-0.06)))

        prefix = rng.choice(FILLER_PREFIXES.get(language, FILLER_PREFIXES["en-US"]))
        candidates.append(("asr_filler_prefix", mutate_asr(row, f"{prefix} {text}", confidence_delta=-0.03)))

        if positive:
            partial = partial_text(text, language)
            if partial and partial != text:
                candidates.append(("partial_fragment", fragment_row(row, partial)))
            candidates.append(("reported_counterfactual", negative_wrapper(row, REPORTED_TEMPLATES, "reported_question")))
            candidates.append(("self_answered_counterfactual", negative_wrapper(row, SELF_ANSWERED_TEMPLATES, "self_answered")))

        selected = candidates if split == "hard_test" else candidates[: max(0, variants_per_row)]
        for index, (kind, candidate) in enumerate(selected):
            candidate["id"] = stable_variant_id(str(row["id"]), kind, index)
            candidate["split"] = split
            yield candidate


def text_for(row: dict[str, Any]) -> str:
    return str(row.get("asr_transcript") or row.get("transcript") or "")


def mutate_asr(row: dict[str, Any], asr_text: str, confidence_delta: float = 0.0) -> dict[str, Any]:
    mutated = copy.deepcopy(row)
    mutated["asr_transcript"] = clean_spaces(asr_text)
    if mutated.get("asr_confidence") is not None:
        mutated["asr_confidence"] = clamp(float(mutated["asr_confidence"]) + confidence_delta, 0.45, 0.99)
    mutated["question_span"] = [0, len(mutated["asr_transcript"])]
    return mutated


def fragment_row(row: dict[str, Any], fragment: str) -> dict[str, Any]:
    mutated = mutate_asr(row, fragment, confidence_delta=-0.12)
    mutated["transcript"] = str(row.get("transcript") or text_for(row))
    mutated["is_partial"] = True
    mutated["complete"] = False
    mutated["response_needed"] = False
    mutated["critical_negative"] = True
    mutated["label"] = "fragment"
    duration_ms = max(400, int((int(row["end_ms"]) - int(row["start_ms"])) * 0.45))
    mutated["end_ms"] = int(row["start_ms"]) + duration_ms
    return mutated


def negative_wrapper(row: dict[str, Any], templates: dict[str, str], label: str) -> dict[str, Any]:
    text = text_for(row)
    language = str(row["language"])
    wrapped = clean_spaces(templates.get(language, templates["en-US"]).format(text=strip_question_mark(text)))
    mutated = copy.deepcopy(row)
    mutated["transcript"] = wrapped
    mutated["asr_transcript"] = wrapped
    mutated["response_needed"] = False
    mutated["critical_negative"] = True
    mutated["complete"] = True
    mutated["is_partial"] = False
    mutated["label"] = label
    mutated["question_span"] = [0, len(wrapped)]
    if mutated.get("asr_confidence") is not None:
        mutated["asr_confidence"] = clamp(float(mutated["asr_confidence"]) - 0.04, 0.50, 0.99)
    return mutated


def strip_punctuation(text: str) -> str:
    return clean_spaces(re.sub(r"[?¿!¡.,;:。、「」『』（）()]+", " ", text))


def strip_question_mark(text: str) -> str:
    return clean_spaces(re.sub(r"[?¿？]+$", "", text.strip()))


def remove_accents(text: str) -> str:
    replacements = str.maketrans(
        {
            "á": "a",
            "à": "a",
            "ã": "a",
            "â": "a",
            "é": "e",
            "ê": "e",
            "í": "i",
            "ó": "o",
            "õ": "o",
            "ô": "o",
            "ú": "u",
            "ü": "u",
            "ç": "c",
            "ñ": "n",
            "Á": "A",
            "À": "A",
            "Ã": "A",
            "Â": "A",
            "É": "E",
            "Ê": "E",
            "Í": "I",
            "Ó": "O",
            "Õ": "O",
            "Ô": "O",
            "Ú": "U",
            "Ü": "U",
            "Ç": "C",
            "Ñ": "N",
        }
    )
    return text.translate(replacements)


def partial_text(text: str, language: str) -> str:
    if language == "ja-JP":
        return text[: max(2, min(8, len(text) // 2))]
    tokens = TOKEN_RE.findall(text)
    if len(tokens) < 4:
        return ""
    return " ".join(tokens[: min(4, max(2, len(tokens) // 2))])


def clean_spaces(text: str) -> str:
    return " ".join(text.split()).strip()


def clamp(value: float, lower: float, upper: float) -> float:
    return max(lower, min(upper, value))


def stable_variant_id(row_id: str, kind: str, index: int) -> str:
    digest = hashlib.sha1(f"{row_id}:{kind}:{index}".encode("utf-8")).hexdigest()[:10]
    return f"{row_id}__{kind}__{digest}"


def split_report(rows: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "rows": len(rows),
        "positive": sum(1 for row in rows if bool(row.get("response_needed", False))),
        "negative": sum(1 for row in rows if not bool(row.get("response_needed", False))),
        "critical_negative": sum(1 for row in rows if bool(row.get("critical_negative", False))),
        "by_language": dict(sorted(Counter(str(row["language"]) for row in rows).items())),
        "by_label": dict(sorted(Counter(str(row["label"]) for row in rows).items())),
    }


if __name__ == "__main__":
    raise SystemExit(main())
