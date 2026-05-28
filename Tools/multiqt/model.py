#!/usr/bin/env python3
"""A compact audio+text model used by the Notchly MultiQT training scripts."""

from __future__ import annotations

import torch
from torch import nn


class MultiQTConcatModel(nn.Module):
    def __init__(
        self,
        vocab_size: int,
        label_count: int,
        scalar_count: int,
        embedding_dim: int = 128,
        hidden_dim: int = 192,
        padding_idx: int = 0,
    ) -> None:
        super().__init__()
        self.embedding = nn.Embedding(vocab_size, embedding_dim, padding_idx=padding_idx)
        self.text_encoder = nn.Sequential(
            nn.Conv1d(embedding_dim, hidden_dim, kernel_size=3, padding=1),
            nn.GELU(),
            nn.Conv1d(hidden_dim, hidden_dim, kernel_size=3, padding=1),
            nn.GELU(),
            nn.AdaptiveMaxPool1d(1),
        )
        self.audio_encoder = nn.Sequential(
            nn.Conv2d(1, 32, kernel_size=3, padding=1),
            nn.GELU(),
            nn.MaxPool2d((2, 2)),
            nn.Conv2d(32, 64, kernel_size=3, padding=1),
            nn.GELU(),
            nn.MaxPool2d((2, 2)),
            nn.Conv2d(64, 96, kernel_size=3, padding=1),
            nn.GELU(),
            nn.AdaptiveAvgPool2d((1, 1)),
        )
        fused_dim = hidden_dim + 96 + scalar_count
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
        embedded = self.embedding(text_tokens.long()).transpose(1, 2)
        text_features = self.text_encoder(embedded).squeeze(-1)
        audio_features = self.audio_encoder(audio_logmel.float().unsqueeze(1)).flatten(1)
        fused = self.fusion(torch.cat([text_features, audio_features, scalars.float()], dim=1))
        return (
            self.response_head(fused).squeeze(-1),
            self.label_head(fused),
            self.complete_head(fused).squeeze(-1),
            self.rhetorical_head(fused).squeeze(-1),
        )
