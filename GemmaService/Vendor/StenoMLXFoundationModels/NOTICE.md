# StenoMLXFoundationModels

This directory vendors the smallest Foundation Models adapter subtree from
[`ml-explore/mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) at
revision `37688d2cf7d3906e08c74479c9d9949ce6b81136`.

The copied source files retain their upstream copyright notices.
The upstream repository is MIT licensed, Copyright (c) 2024 ml-explore.

Steno's changes add the stored-container initialization path for an already
verified local `ModelContainer` and its immutable `ModelDescriptor`.
