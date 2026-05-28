# Notchly MultiQT Training Toolchain

This directory is the offline training/export workspace for the trained MultiQT-style realtime question tracker.

The app ships a deterministic MultiQT-lite fallback plus a trained Core ML runtime. The bundled bootstrap checkpoint is `NotchCopilot/Resources/Models/notchly-multiqt-v1.mlmodelc` with sidecar metadata.

See the full execution plan:

`docs/MULTIQT_FINAL_CONSOLIDATION_PLAN.md`

## Required artifacts

Expected input layout:

```text
Data/multiqt/
  train.jsonl
  dev.jsonl
  test.jsonl
  hard_test.jsonl
  audio/
    ...
```

Expected output layout:

```text
Artifacts/multiqt/
  best.pt
  metrics.json
  calibration.json
  errors.jsonl
  notchly-multiqt-v1.mlpackage
  notchly-multiqt-v1.metadata.json
```

Bootstrap a synthetic speech manifest from the existing QA gold fixture:

```sh
python3 Tools/multiqt/build_synthetic_manifest.py \
  --out-dir Data/multiqt_synthetic \
  --generate-audio \
  --jobs 4
```

Synthetic speech is only a bootstrap set. The final production gate still requires consented real meeting audio, public/license-compatible audio, or manually reviewed local datasets.

## Commands

Install offline training dependencies on the training machine:

```sh
python3 -m pip install -r Tools/multiqt/requirements.txt
```

Validate manifests before training:

```sh
python3 Tools/multiqt/validate_manifest.py \
  Data/multiqt/train.jsonl \
  Data/multiqt/dev.jsonl \
  Data/multiqt/test.jsonl \
  Data/multiqt/hard_test.jsonl \
  --audio-root Data/multiqt \
  --check-audio
```

Manifests may include `audio_feature_path` and `audio_feature_source` (`logmel`, `signal_proxy`, or `synthetic_logmel`). The production app never stores raw audio for this path: runtime inference consumes an in-memory `QuestionAudioLogMelFeature` derived from the short-lived live PCM ring buffer when available, otherwise it falls back to a redacted numeric proxy from RMS, peak, energy, noise, duration, pause, confidence, and stability signals.

Harden a bootstrap manifest with deterministic ASR and intent stress cases:

```sh
python3 Tools/multiqt/augment_manifest.py \
  --input-dir Data/multiqt_synthetic \
  --out-dir Data/multiqt_hardened \
  --augment-eval \
  --train-asr-variants 4 \
  --eval-asr-variants 2
```

Import redacted shadow logs into a privacy-preserving active-learning manifest:

```sh
python3 Tools/multiqt/build_shadow_manifest.py \
  --input Data/multiqt_shadow/redacted_shadow_logs.jsonl \
  --out Data/multiqt_shadow/shadow_redacted.jsonl
python3 Tools/multiqt/validate_manifest.py \
  Data/multiqt_shadow/shadow_redacted.jsonl \
  --check-audio
```

Shadow rows must declare `redacted=true` or `privacy.redacted=true` and use `redacted_text`/`asr_text_redacted`. The importer rejects raw transcript fields, raw snippets, audio paths, audio blobs, email/phone/API-key-like identifiers, and emits `audio_feature_source=signal_proxy` so training can consume numeric acoustic/temporal signals without raw meeting audio.

Smoke-test the toolchain without audio files:

```sh
python3 Tools/multiqt/validate_manifest.py Tools/multiqt/fixtures/tiny_manifest.jsonl
python3 Tools/multiqt/evaluate.py \
  --manifest Tools/multiqt/fixtures/tiny_manifest.jsonl \
  --predictions Tools/multiqt/fixtures/tiny_predictions.jsonl \
  --no-gates
```

```sh
python3 Tools/multiqt/train.py \
  --manifest Data/multiqt/train.jsonl \
  --dev Data/multiqt/dev.jsonl \
  --test Data/multiqt/test.jsonl \
  --hard-test Data/multiqt/hard_test.jsonl \
  --out Artifacts/multiqt \
  --input-mode multimodal \
  --max-frames 240
```

Train/evaluate modality baselines with the same split, seed, architecture, and threshold policy:

```sh
python3 Tools/multiqt/compare_baselines.py \
  --manifest Data/multiqt_hardened/train.jsonl \
  --dev Data/multiqt_hardened/dev.jsonl \
  --test Data/multiqt_hardened/test.jsonl \
  --hard-test Data/multiqt_hardened/hard_test.jsonl \
  --audio-root Data/multiqt_synthetic \
  --out Artifacts/multiqt_baselines \
  --epochs 16 \
  --batch-size 64 \
  --critical-negative-weight 2.5 \
  --max-frames 240
```

Supported `--input-mode`/baseline modes are `multimodal`, `text_only`, `audio_only`, `text_audio`, and `scalar_only`. The model keeps one architecture and masks unused modalities, so comparisons are reproducible and do not fork runtime behavior.

```sh
python3 Tools/multiqt/predict.py \
  --checkpoint Artifacts/multiqt/best.pt \
  --manifest Data/multiqt/hard_test.jsonl \
  --out Artifacts/multiqt/hard_test_predictions.jsonl
```

```sh
python3 Tools/multiqt/evaluate.py \
  --manifest Data/multiqt/hard_test.jsonl \
  --predictions Artifacts/multiqt/hard_test_predictions.jsonl \
  --out Artifacts/multiqt/hard_test_metrics.json
```

```sh
python3 Tools/multiqt/export_coreml.py \
  --checkpoint Artifacts/multiqt/best.pt \
  --out Artifacts/multiqt/notchly-multiqt-v1.mlpackage \
  --training-report Data/multiqt_hardened/augmentation_report.json \
  --baseline-comparison Artifacts/multiqt_baselines/baseline_comparison.json
```

Compile and bundle for the app:

```sh
xcrun coremlcompiler compile \
  Artifacts/multiqt/notchly-multiqt-v1.mlpackage \
  Artifacts/multiqt/compiled
cp -R Artifacts/multiqt/compiled/notchly-multiqt-v1.mlmodelc \
  NotchCopilot/Resources/Models/
cp Artifacts/multiqt/notchly-multiqt-v1.metadata.json \
  NotchCopilot/Resources/Models/
```

## Gate summary

- overall precision >= 0.995
- overall recall >= 0.970
- critical negative false positives == 0
- pt-BR/en-US/es-ES/ja-JP precision >= 0.990 each
- pt-BR/en-US/es-ES/ja-JP recall >= 0.950 each
- p95 local decision <= 60 ms on target Mac hardware
- p99 local decision <= 100 ms

## Bundled bootstrap checkpoint

The current bundled checkpoint was trained from the QA gold fixture converted into synthetic audio with macOS `say`, then hardened with deterministic ASR/intent augmentations.

- rows: 6,794 total; 2,163 positive; 4,631 negative
- languages: pt-BR, en-US, es-ES, ja-JP
- threshold: 0.99
- critical negative weight: 2.5
- threshold calibration: selected by global, per-language, and critical-negative-label gates on dev
- exported runtime policy: `label_policy` plus `language_thresholds`, so Core ML label predictions for critical negatives can hard-suppress candidates
- test: TP 190, FP 0, FN 0, TN 326, precision 1.0000, recall 1.0000, p95 2.128 ms
- hard_test: TP 123, FP 0, FN 0, TN 321, precision 1.0000, recall 1.0000, p95 1.580 ms

Baseline comparison, 16 epochs, seed 42:

| Mode | test precision/recall | hard_test precision/recall | hard_test Critical FP | test p95 |
| --- | ---: | ---: | ---: | ---: |
| `multimodal` | 1.0000 / 1.0000 | 1.0000 / 1.0000 | 0 | 2.128 ms |
| `text_only` | 1.0000 / 1.0000 | 0.9919 / 1.0000 | 1 | 1.608 ms |
| `audio_only` | 0.9649 / 0.2895 | 0.5000 / 0.2195 | 27 | 3.911 ms |

This checkpoint proves the runtime path and is safe to ship as a local-first hardened bootstrap in `enforced` (`promotion.promote_to_enforced = true`). It is not the final production evidence set; that still requires consented real meeting audio and shadow replay.

The baseline report also stores detailed gates. Current bundled metadata has 63/63 gates passing: overall precision/recall, per-language precision/recall, p95/p99 latency, zero critical FP globally, and zero critical FP by negative label. Metadata also stores the critical-negative label list and per-language thresholds used by the Swift runtime.

## Privacy

Raw audio is never persisted by default in the app. Training manifests may reference audio only when the user opted into a local/manual dataset or when the source is public/synthetic and license-compatible. Shadow logs must remain redacted and must not contain raw snippets or raw audio.
