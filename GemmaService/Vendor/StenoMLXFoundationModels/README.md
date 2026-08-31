# Steno MLX Foundation Models adapter

This is a minimal, locally vendored Foundation Models adapter from
`mlx-swift-lm` revision `37688d2cf7d3906e08c74479c9d9949ce6b81136`.

It adds a package-local stored-container initializer for a prebuilt
`ModelContainer`.
The adapter derives its immutable `ModelDescriptor` internally from the same
container's configuration and tokenizer plus verified model type/config data.
That path intentionally owns no filesystem resolver, loader closure, or model
cache entry.

Keep this directory aligned with that exact upstream revision.
When updating it, replace only the adapter subtree, preserve all file-level
copyright notices, and update `NOTICE.md` and `LICENSE` together.
