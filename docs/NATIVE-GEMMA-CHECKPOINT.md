# Native Gemma checkpoint

## Selected checkpoint

Steno targets exactly [`mlx-community/gemma-4-e2b-it-4bit`](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit/tree/238767527555cb75a05732a84dff5d6ba0dd6809) at immutable revision `238767527555cb75a05732a84dff5d6ba0dd6809`.
The conversion identifies [`google/gemma-4-E2B-it`](https://huggingface.co/google/gemma-4-E2B-it/tree/70af34e20bd4b7a91f0de6b22675850c43922a03) at revision `70af34e20bd4b7a91f0de6b22675850c43922a03` as its base.
The checkpoint uses 4-bit affine quantization with group size 64.
The Hugging Face repository contains ten files totalling 3,583,088,661 bytes, or about 3.34 GiB.
Steno imports only the seven runtime files below, totalling 3,583,085,182 bytes.
The repository-only `.gitattributes`, `README.md`, and `processor_config.json` files are not part of the installed runtime snapshot.

The exact Steno import manifest is [`model-manifests/gemma-4-e2b-it-4bit/gemma-model-manifest.json`](model-manifests/gemma-4-e2b-it-4bit/gemma-model-manifest.json).
Its SHA-256 digest is `dab4d380ff03b1e6ac34fa47a0db672e540ee399b9d04dc765ba832a6f59cca5`.

| Runtime file | Bytes | SHA-256 |
|---|---:|---|
| `chat_template.jinja` | 17,336 | `2f1b4d75d067bae3fe44e676721c7f077d243bc007156cb9c2f8b5836613d082` |
| `config.json` | 6,395 | `6397cb6eca41b911d1dcab74e17941351057bd759284052a2331918ff6f9246c` |
| `generation_config.json` | 208 | `d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de` |
| `model.safetensors` | 3,550,670,554 | `038e39a37a7667373d2c3991375446b10c96ae1d717a68674870343db376b76e` |
| `model.safetensors.index.json` | 218,323 | `edb157dbf495e23f37377af4a628a9ad13c4ee7937f93ccb36ec9e9a19940f16` |
| `tokenizer.json` | 32,169,626 | `cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f` |
| `tokenizer_config.json` | 2,740 | `080d9e1aff284e2f6043889cd05367966f7c7b80e025fbc0b06745e218158656` |

## License status

The conversion repository card declares `gemma`, while the exact Google base-model card declares `apache-2.0` and links to Google's Gemma 4 license page.
Steno records the conservative `gemma` identifier for this checkpoint and must display that discrepancy before import.
This developer integration does not establish redistribution rights, so the discrepancy must be resolved before Steno distributes checkpoint files or presents the model as Apache-2.0 licensed.

## Resource envelope

Google's published Gemma 4 table estimates 2.9 GB for E2B Q4 static inference weights and explicitly excludes supporting software and the context-window cache.
The current path-free Steno activation also holds the 3.55 GB Safetensors shard as a byte buffer while it materializes the 2.60 GB text tensor payload.
On 31 August 2026, the bounded local smoke test ran on an Apple Silicon Mac with 24 GiB of memory and macOS 27.0.
It started with 60 percent system memory free and retained the 8 GiB helper-resident-memory abort ceiling.
The exact local-folder import, sandboxed helper activation, native provider selection, and a real Standup report completed in the Steno app.
Peak helper RSS was 1,971,600 KiB, or 1.88 GiB, and memory pressure never became critical.
The generated report contained real `Updates`, `Blockers`, and `Participants` sections from the synthetic demo transcript.
This validates one short local report on the test machine, but it does not establish production support or checkpoint redistribution rights.
A Meeting Minutes run under the same 256-token response budget reached inference but did not satisfy Steno's strict JSON result contract, so longer-template coverage remains open.

## Required loader delta

The pinned checkpoint uses `Gemma4ForConditionalGeneration` with a nested `gemma4_text` model and five exact top-level weight namespaces.
Steno needs the existing exact activation profile to accept that wrapper, verify all 2,511 tensor descriptors and the complete index, discard only `audio_tower`, `vision_tower`, `embed_audio`, and `embed_vision` arrays before MLX evaluation, and evaluate only `language_model` arrays.
No media input, vision capability, general multimodal policy, or other checkpoint layout is enabled.
