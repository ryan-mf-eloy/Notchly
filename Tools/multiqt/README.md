# Notchly MultiQT Training Toolchain

This directory is the offline training/export workspace for the final trained MultiQT-style realtime question tracker.

The app currently ships a deterministic MultiQT-lite fallback. The final target is a trained audio+text sequence model exported to Core ML as `notchly-multiqt-v1.mlmodelc`.

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
```

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
  --out Artifacts/multiqt
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
  --out NotchCopilot/Resources/Models/notchly-multiqt-v1.mlpackage
```

## Gate summary

- overall precision >= 0.995
- overall recall >= 0.970
- critical negative false positives == 0
- pt-BR/en-US/es-ES/ja-JP precision >= 0.990 each
- pt-BR/en-US/es-ES/ja-JP recall >= 0.950 each
- p95 local decision <= 60 ms on target Mac hardware
- p99 local decision <= 100 ms

## Privacy

Raw audio is never persisted by default in the app. Training manifests may reference audio only when the user opted into a local/manual dataset or when the source is public/synthetic and license-compatible. Shadow logs must remain redacted and must not contain raw snippets or raw audio.
