# Synthetic demo dataset attribution

The three bundled WAV files were generated locally on 23 August 2026 from entirely fictional German scripts.
They contain no recordings of real people, company data, CCC material, or AMI material.

## Speech generator

The development-time generator was [rhasspy/piper](https://github.com/rhasspy/piper/tree/38917ffd8c0e219c6581d73e07b30ef1d572fce1) at commit `38917ffd8c0e219c6581d73e07b30ef1d572fce1`, licensed under MIT.

The voice repository was [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices/tree/7e8200c80dbc9147404face0d3ee0bb69995d873) at revision `7e8200c80dbc9147404face0d3ee0bb69995d873`, licensed under MIT.

Generation used the `de_DE-mls-medium` voice with model speaker indices `0`, `1`, and `5`.
The corresponding model speaker IDs recorded in the generation manifest are `2422`, `4536`, and `6507`.

## Training-data attribution

The voice model card identifies its training material as Multilingual LibriSpeech, distributed as [OpenSLR SLR94](https://www.openslr.org/94/) under the [Creative Commons Attribution 4.0 International license](https://creativecommons.org/licenses/by/4.0/).

Attribution: Vineel Pratap and the Multilingual LibriSpeech contributors, "MLS: A Large-Scale Multilingual Dataset for Speech Research," Interspeech 2020.

The committed WAV files are generated and mixed outputs, not copies of the MLS recordings.
They use fictional scripts, selected model speakers, explicit timing, and adjusted gain levels.

## Unbundled development dependencies

eSpeak NG `2023.9.7-4` at [commit `5c3a2e79c24f92cd408d067a9aa47553927ec891`](https://github.com/rhasspy/espeak-ng/tree/5c3a2e79c24f92cd408d067a9aa47553927ec891) is licensed under GPL-3.0-or-later.
It was used only as an unbundled development dependency of the generator.
The repository's small patch to eSpeak NG build configuration is also offered under GPL-3.0-or-later.

The exact artifact URLs, revisions, byte counts, checksums, and licenses are recorded in `scripts/demo/demo-script.json` and `docs/DEMO-FIXTURE.md`.
