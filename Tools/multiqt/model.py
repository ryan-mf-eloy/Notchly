#!/usr/bin/env python3
"""A compact audio+text model used by the Notchly MultiQT training scripts."""

from __future__ import annotations

import torch
from torch import nn


MODEL_INPUT_MODES = ("multimodal", "text_only", "audio_only", "text_audio", "scalar_only")
AUDIO_ENCODERS = ("summary_stats", "temporal_cnn")


class MultiQTConcatModel(nn.Module):
    def __init__(
        self,
        vocab_size: int,
        label_count: int,
        scalar_count: int,
        input_mode: str = "multimodal",
        audio_encoder: str = "temporal_cnn",
        embedding_dim: int = 128,
        hidden_dim: int = 192,
        padding_idx: int = 0,
    ) -> None:
        super().__init__()
        if input_mode not in MODEL_INPUT_MODES:
            raise ValueError(f"Unsupported input mode: {input_mode}")
        if audio_encoder not in AUDIO_ENCODERS:
            raise ValueError(f"Unsupported audio encoder: {audio_encoder}")
        self.input_mode = input_mode
        self.audio_encoder_name = audio_encoder
        self.text_feature_dim = hidden_dim
        self.audio_feature_dim = 96
        self.embedding = nn.Embedding(vocab_size, embedding_dim, padding_idx=padding_idx)
        self.text_encoder = nn.Sequential(
            nn.Conv1d(embedding_dim, hidden_dim, kernel_size=3, padding=1),
            nn.GELU(),
            nn.Conv1d(hidden_dim, hidden_dim, kernel_size=3, padding=1),
            nn.GELU(),
            nn.AdaptiveMaxPool1d(1),
        )
        if audio_encoder == "summary_stats":
            self.audio_encoder = nn.Sequential(
                nn.Linear(40 * 3, 128),
                nn.LayerNorm(128),
                nn.GELU(),
                nn.Linear(128, 96),
                nn.GELU(),
            )
        else:
            self.audio_encoder = nn.Sequential(
                nn.Conv1d(40, 128, kernel_size=5, padding=2),
                nn.GELU(),
                nn.Conv1d(128, 128, kernel_size=5, padding=2, stride=2),
                nn.GELU(),
                nn.Conv1d(128, 96, kernel_size=3, padding=1),
                nn.GELU(),
                nn.AdaptiveMaxPool1d(1),
            )
        fused_dim = self.text_feature_dim + self.audio_feature_dim + scalar_count
        self.fusion = nn.Sequential(
            nn.Linear(fused_dim, hidden_dim),
            nn.LayerNorm(hidden_dim),
            nn.GELU(),
            nn.Dropout(0.15),
            nn.Linear(hidden_dim, hidden_dim),
            nn.GELU(),
        )
        self.response_head = nn.Linear(hidden_dim, 1)
        self.label_head = nn.Linear(hidden_dim, label_count)
        self.complete_head = nn.Linear(hidden_dim, 1)
        self.rhetorical_head = nn.Linear(hidden_dim, 1)

    def forward(
        self,
        text_tokens: torch.Tensor,
        audio_logmel: torch.Tensor,
        scalars: torch.Tensor,
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        batch_size = text_tokens.shape[0]
        scalar_features = scalars.float()
        if self.input_mode in {"audio_only", "scalar_only"}:
            text_features = torch.zeros(batch_size, self.text_feature_dim, device=scalar_features.device)
        else:
            embedded = self.embedding(text_tokens.long()).transpose(1, 2)
            text_features = self.text_encoder(embedded).squeeze(-1)

        if self.input_mode in {"text_only", "scalar_only"}:
            audio_features = torch.zeros(batch_size, self.audio_feature_dim, device=scalar_features.device)
        else:
            audio = audio_logmel.float()
            if self.audio_encoder_name == "summary_stats":
                audio_summary = torch.cat(
                    [
                        audio.mean(dim=2),
                        torch.amax(audio, dim=2),
                        torch.amin(audio, dim=2),
                    ],
                    dim=1,
                )
                audio_features = self.audio_encoder(audio_summary)
            else:
                audio_features = self.audio_encoder(audio).squeeze(-1)

        if self.input_mode in {"text_only", "audio_only", "text_audio"}:
            scalar_features = torch.zeros_like(scalar_features)
        fused = self.fusion(torch.cat([text_features, audio_features, scalar_features], dim=1))
        return (
            self.response_head(fused).squeeze(-1),
            self.label_head(fused),
            self.complete_head(fused).squeeze(-1),
            self.rhetorical_head(fused).squeeze(-1),
        )
