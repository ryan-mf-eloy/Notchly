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

Build the expanded multilingual regression manifest from both QA and Copilot intent gold fixtures without storing audio:

```sh
python3 Tools/multiqt/build_synthetic_manifest.py \
  --out-dir Data/multiqt_expanded \
  --include-copilot-fixture \
  --audio-feature-source signal_proxy
```

The expanded path maps Copilot-only intents (`calculation`, `conversion`, `news`, `web`, `reminder`, `memory`) into the MultiQT answerability schema while preserving response-needed truth labels. It also preserves `candidateDetection`/`candidate_detection` and `surfaceMiss`/`surface_miss` rows, which train the candidate-rescue head for answerable frames the textual surface detector missed. `signal_proxy` rows are trainable from numeric acoustic/temporal fields and remain a bootstrap/CI path, not a substitute for consented real meeting audio.

For quick audio smoke datasets, use `--max-rows-per-label N` instead of `--max-rows N` so positives and critical negatives stay represented across the small sample.

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

Manifests may include `audio_feature_path` and `audio_feature_source` (`logmel`, `signal_proxy`, or `synthetic_logmel`). The production app never stores raw audio for this path. Runtime inference follows the exported `audio_feature_contract`: checkpoints trained on log-mel can consume an in-memory `QuestionAudioLogMelFeature` derived from the short-lived live PCM ring buffer, while `signal_proxy` checkpoints consume a redacted numeric proxy from RMS, peak, energy, noise, duration, pause, confidence, and stability signals.

Materialize log-mel features from a synthetic/public/consented audio manifest so training no longer needs raw waveform access:

```sh
python3 Tools/multiqt/materialize_audio_features.py \
  --input-dir Data/multiqt_synthetic \
  --out-dir Data/multiqt_logmel \
  --feature-source synthetic_logmel \
  --redact-audio-path
python3 Tools/multiqt/validate_manifest.py \
  Data/multiqt_logmel/train.jsonl \
  Data/multiqt_logmel/dev.jsonl \
  Data/multiqt_logmel/test.jsonl \
  Data/multiqt_logmel/hard_test.jsonl \
  --audio-root Data/multiqt_logmel \
  --check-audio
```

`synthetic_logmel` rows are fixed 40 x `max_frames` `.npy` tensors. They keep the same Core ML input contract as live `logmel`, but remain bootstrap evidence unless the source audio is consented real meeting audio or public/license-compatible speech.

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
  --audio-encoder temporal_cnn \
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
  --min-threshold 0.50 \
  --device auto \
  --audio-encoder temporal_cnn \
  --max-frames 240
```

Supported `--input-mode`/baseline modes are `multimodal`, `text_only`, `audio_only`, `text_audio`, and `scalar_only`. The model keeps one architecture and masks unused modalities, so comparisons are reproducible and do not fork runtime behavior. `--audio-encoder temporal_cnn` is available for new candidate checkpoints and uses a separate temporal convolutional encoder over 40-band log-mel/proxy frames; `summary_stats` remains available for the currently bundled bootstrap checkpoint and for compatibility re-exports. Promotion is precision-first: multimodal must pass absolute precision/recall/latency/critical-FP gates and must improve precision or critical-FP behavior over text-only while preserving absolute recall gates.

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
  --baseline-comparison Artifacts/multiqt_baselines/baseline_comparison.json \
  --preferred-runtime-feature auto
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

The current bundled checkpoint was trained from `qa_intent_gold.jsonl` plus `copilot_intent_gold.jsonl` with `audio_feature_source=signal_proxy`, then hardened with deterministic ASR/intent augmentations.

- rows: 94,222 total; 34,087 positive; 60,135 negative
- languages: pt-BR, en-US, es-ES, ja-JP
- threshold: 0.55 global; language thresholds `pt-BR=0.55`, `en-US=0.99`, `es-ES=0.99`, `ja-JP=0.99`
- critical negative weight: 2.5
- threshold calibration: selected by global, per-language, and critical-negative-label gates on dev
- exported runtime policy: `label_policy` plus `language_thresholds`, so Core ML label predictions for critical negatives can hard-suppress candidates
- exported rescue policy: new checkpoints may include `candidate_logit` for candidate detection before textual acceptance; older four-output bundles stay loadable and use `response_logit` as the rescue fallback
- exported audio contract: `preferred_runtime_feature=signal_proxy`, matching the proxy acoustic/temporal features used during training
- test: TP 3425, FP 0, FN 1, TN 4596, precision 1.0000, recall 0.9997, p95 0.002 ms
- hard_test: TP 2076, FP 0, FN 0, TN 4309, precision 1.0000, recall 1.0000, p95 0.002 ms

A `temporal_cnn` candidate trained on the same 94,222-row hardened set passed the aggregate gates, but it was not promoted because the Core ML runtime smoke for the live pt-BR phrase `Quais sao os principios SOLID de programacao` fell below threshold. The shipped bundle therefore remains the `summary_stats`/`signal_proxy` checkpoint until a temporal/log-mel candidate passes both aggregate gates and targeted qualitative smokes.

Baseline comparison, 16 epochs, seed 42:

| Mode | test precision/recall | hard_test precision/recall | hard_test Critical FP | test p95 |
| --- | ---: | ---: | ---: | ---: |
| `multimodal` | 1.0000 / 0.9997 | 1.0000 / 1.0000 | 0 | 0.002 ms |
| `text_only` | 1.0000 / 0.9982 | 1.0000 / 0.9986 | 0 | 0.002 ms |
| `audio_only` | 1.0000 / 0.3357 | 1.0000 / 0.3348 | 0 | 0.002 ms |

This checkpoint proves the runtime path and is safe to ship as a local-first hardened bootstrap in `enforced` (`promotion.promote_to_enforced = true`). It is not the final production evidence set; that still requires consented real meeting audio and shadow replay.

The baseline report also stores detailed gates. Current bundled metadata has 67/67 gates passing: overall precision/recall, per-language precision/recall, p95/p99 latency, zero critical FP globally, and zero critical FP by negative label. Metadata also stores the critical-negative label list, per-language thresholds, and preferred runtime audio feature used by the Swift runtime.

Runtime rescue replay on 2026-05-28 with the expanded gold fixture reports `surface_candidate_recall=0.9963`, `surface_plus_multiqt_recall=1.0000`, `rescue_tp=3`, `rescue_fp=0`, `critical_fp=0`, and `multimodal_p95=23.325 ms`. This validates the Swift rescue path with deterministic candidate-detection labels; promotion of a newly trained `candidate_logit` bundle still requires aggregate gates plus qualitative pt-BR/en-US/es-ES/ja-JP smokes.

## Privacy

Raw audio is never persisted by default in the app. Training manifests may reference audio only when the user opted into a local/manual dataset or when the source is public/synthetic and license-compatible. Shadow logs must remain redacted and must not contain raw snippets or raw audio.
