# Third-party notices

Steno's source code is licensed under MIT except where a file or bundled resource states otherwise.

## FluidAudio

StenoKit depends on [FluidAudio](https://github.com/FluidInference/FluidAudio), pinned through `StenoKit/Package.resolved`.
FluidAudio's own license and notices apply to that dependency.

## Native Gemma service dependencies

The experimental `GemmaService` package uses `mlx-swift` at exact revision `0bb916c67f4b9e5c682cbe02a42c701c93ab5021` under the MIT license, Copyright (c) 2023 ml-explore.
It uses `mlx-swift-lm` at exact revision `37688d2cf7d3906e08c74479c9d9949ce6b81136` under the MIT license, Copyright (c) 2024 ml-explore.
The package vendors a minimal `MLXFoundationModels` adapter subtree from that `mlx-swift-lm` revision, with its local changes documented in `GemmaService/Vendor/StenoMLXFoundationModels/NOTICE.md`.
The adapter's `MLXGuidedGeneration` integration brings in vendored XGrammar under the Apache-2.0 license, with the notice `XGrammar Copyright (c) 2024 by XGrammar Contributors`.
These dependencies are isolated to the experimental macOS 27 package and are not part of the supported application targets.

## Synthetic demo recordings

The bundled demo recordings were generated with Piper and the `de_DE-mls-medium` voice.
The generator and voice repository are MIT licensed.
The model card identifies its Multilingual LibriSpeech training material as CC BY 4.0.

Full provenance, exact revisions, attribution, and generation details are in the bundled [`ATTRIBUTION.md`](StenoKit/Sources/StenoDemo/Resources/DemoDataset/ATTRIBUTION.md) and [`docs/DEMO-FIXTURE.md`](docs/DEMO-FIXTURE.md).

## Demo-generation tools

The reproducible demo-generation workflow downloads pinned development tools whose licenses are recorded in `scripts/demo/demo-script.json`.
Those tools and models are not bundled with Steno.

The file `scripts/demo/espeak-ng-no-sonic.patch` modifies eSpeak NG build configuration and is offered under GPL-3.0-or-later, matching the upstream file.
