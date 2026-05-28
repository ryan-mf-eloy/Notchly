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

Synthetic speech is only a bootstrap set. The enforced gate still requires consented real meeting audio, public/license-compatible audio, or manually reviewed local datasets.

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

Manifests may include `audio_feature_path` and `audio_feature_source` (`logmel`, `signal_proxy`, or `synthetic_logmel`). The production app never stores raw audio for this path: runtime inference consumes an in-memory `QuestionAudioLogMelFeature` when available, otherwise it falls back to a redacted numeric proxy from RMS, peak, energy, noise, duration, pause, confidence, and stability signals.

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
  --max-frames 240
```

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
  --out Artifacts/multiqt/notchly-multiqt-v1.mlpackage
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

The current bundled checkpoint was trained from the QA gold fixture converted into synthetic audio with macOS `say`.

- rows: 2,021 total; 809 positive; 1,212 negative
- languages: pt-BR, en-US, es-ES, ja-JP
- threshold: 0.99
- test: TP 71, FP 0, FN 0, TN 121, precision 1.0000, recall 1.0000, p95 1.279 ms
- hard_test: TP 47, FP 0, FN 0, TN 72, precision 1.0000, recall 1.0000, p95 1.202 ms

This checkpoint proves the runtime path and is safe to ship as a local-first bootstrap. It is not the final production evidence set; that still requires consented real meeting audio and shadow replay.

## Privacy

Raw audio is never persisted by default in the app. Training manifests may reference audio only when the user opted into a local/manual dataset or when the source is public/synthetic and license-compatible. Shadow logs must remain redacted and must not contain raw snippets or raw audio.
