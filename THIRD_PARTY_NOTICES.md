# Third-party notices

Steno's source code is licensed under MIT except where a file or bundled resource states otherwise.

## FluidAudio

StenoKit depends on [FluidAudio](https://github.com/FluidInference/FluidAudio), pinned through `StenoKit/Package.resolved`.
FluidAudio's own license and notices apply to that dependency.

## Synthetic demo recordings

The bundled demo recordings were generated with Piper and the `de_DE-mls-medium` voice.
The generator and voice repository are MIT licensed.
The model card identifies its Multilingual LibriSpeech training material as CC BY 4.0.

Full provenance, exact revisions, attribution, and generation details are in the bundled [`ATTRIBUTION.md`](StenoKit/Sources/StenoDemo/Resources/DemoDataset/ATTRIBUTION.md) and [`docs/DEMO-FIXTURE.md`](docs/DEMO-FIXTURE.md).

## Demo-generation tools

The reproducible demo-generation workflow downloads pinned development tools whose licenses are recorded in `scripts/demo/demo-script.json`.
Those tools and models are not bundled with Steno.

The file `scripts/demo/espeak-ng-no-sonic.patch` modifies eSpeak NG build configuration and is offered under GPL-3.0-or-later, matching the upstream file.
