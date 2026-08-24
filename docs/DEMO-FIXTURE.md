# Synthetic demo recordings

The bundle contains exactly three pre-rendered fictional German PCM16 mono WAV files at 22,050 Hz.

Their durations are 67.452517 seconds for `projektauftakt`, 59.454240 seconds for `wochenrunde`, and 59.866485 seconds for `produktinterview`.

`projektauftakt` contains two documented short overlaps totaling 0.329161 seconds, with at most two simultaneous voices.
The other two timelines are sequential.

`render-demo-audio.sh` builds only inside a marked task-owned cache under `/private/tmp/steno-demo-generator-*`, verifies every pinned artifact, and bundles neither the model nor the generator.

The current user's effective UID owns the cache.
Its root directory has mode 0700, and its non-symbolic ownership marker has mode 0600.
Before use, the script also verifies ownership, type, and restrictive modes for `runs`, `downloads`, the lock, partial files, and run markers.

Every build runs natively on Apple Silicon in its own temporary subdirectory.
The shared download cache is locked exclusively, and fully verified files are published atomically.

CMake is downloaded from its pinned GHCR digest URL.
The process neither invokes nor modifies Homebrew.

The native Piper invocation sets `--noise_scale 0 --noise_w 0`, making each rendered clip byte-stable with the verified toolchain.

Start positions and levels no longer depend on floating-point calculations.
Every segment has an explicit `startFrame` and an integer gain multiplier with 16 fractional bits.
The multipliers are 65,536 for 0 dB, 58,409 for -1 dB, and 61,870 for -0.5 dB.
Human-readable `start` and `gainDB` values remain as documentation and are checked against these authoritative integers.

Level adjustment rounds positive and negative PCM values to the nearest integer, with exact halves rounded away from zero.
The mixer records the input peak, pre-limit peak, clipped-sample count, frame count, and output peak.
The normal clipping budget is zero, and all three frozen files were generated with zero clipped samples.

Audio, timeline, and metrics are first written to unique partial files.
The WAV file is published atomically only after successful validation and after its companion artifacts.

The wrapper additionally retains all three meetings in a unique run staging area.
It verifies the script hash, meeting set, zero-clipping condition, and every frozen WAV size and hash before publishing a previously absent destination as one complete directory tree.
Optional evidence is also published as a complete tree before the final audio output tree.

On macOS, the final directory commit calls `renamex_np` with `RENAME_EXCL` directly.
It therefore cannot replace a destination that appears between preflight and commit or adopt it as a parent directory.

If the final output-tree commit fails after evidence has already been published, the wrapper renames only its own evidence tree, identified by device and inode, back to its original staging name using an exclusive rename and then cleans it up under controlled conditions.
If identity differs, the discovered tree remains untouched and the run fails closed.

Two complete native runs using the same verified download cache but fresh source, build, install, and render directories produced byte-identical WAV files, timelines, and metrics.

Verified toolchain: macOS 26.5.2 build 25F84, Xcode 26.6 build 17F113, Apple Clang 21.0.0 `clang-2100.1.1.101`, Python 3.14.7, jq 1.7.1-apple, and CMake 4.4.2.

Piper was pinned to `38917ffd8c0e219c6581d73e07b30ef1d572fce1`, Piper Phonemize to `7e9174083b94fcc3c51c983a2394593abd81925b`, and eSpeak NG to `5c3a2e79c24f92cd408d067a9aa47553927ec891`.
A small pinned patch removes eSpeak's Sonic fetch, which otherwise runs even with `USE_LIBSONIC` disabled.

All pins, URLs, byte counts, checksums, licenses, and the common verification date of 23 August 2026 are recorded in `scripts/demo/demo-script.json`.

Piper and Piper Voices were verified as MIT licensed.
The voice model card identifies its MLS training material as CC BY 4.0.
eSpeak NG is GPL-3.0-or-later and remains an unbundled development dependency.

No confirmed listening path was available during generation.
Manual listening acceptance for intelligibility, voice separation, and the two short overlaps remains open.
