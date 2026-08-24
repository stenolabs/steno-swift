# Local text-model providers: real-system acceptance

Status: 13 August 2026.

## Scope and privacy

Steno's native Ollama dialect was tested against an approved CachyOS machine on the local network.
Every request contained only sentences created specifically for this test.
No stored meeting, transcript, audio, participant name, or API key was transmitted.

The LM Studio endpoint on `localhost:1234` was inactive during this acceptance run and was not contacted again.
This does not supersede the previously documented real LM Studio test.

## Environment

| Component | Verified configuration |
|---|---|
| Ollama host | CachyOS Linux `7.1.4-1-cachyos`, Ollama `0.32.4` |
| GPU | NVIDIA GeForce RTX 4070 Ti, 12,282 MiB VRAM |
| System memory | 31 GiB |
| Steno endpoint | `http://<ollama-host>:11434`, `ollama` dialect, self-hosted |
| Primary model | `gemma4:12b`, Q4_K_M, 7.6 GB |
| Working context | 16,384 tokens |
| Comparison model | `steno-gemma4:26b-16k`, Q4_K_M, 17 GB |

Ollama reported a theoretical 262,144-token context window for the Gemma 4 base models.
Steno deliberately used 16,384 tokens to constrain the local KV cache and keep MapReduce behavior reproducible.
The native Steno probe currently reports only the configured context; the independently read server value is not presented as the provider value.

## Results

### Gemma 4 12B

| Check | Result |
|---|---|
| Model list through `/api/tags` | Passed, exact model identifier found |
| Structured generation through `/api/chat` | Passed |
| Provider descriptor | `ollama-native` |
| German output | Passed |
| Note spelling `Stadt Musterstadt` | Passed |
| Short probe | 2.1 to 4.7 seconds with warm or cold model state |
| Direct structured generation | 2.5 to 3.1 seconds |
| Long synthetic MapReduce run | Three map calls, one reduce call, 20.3 seconds |
| iPad Simulator through the same LAN endpoint | Passed, one test in 9.0 seconds |

The long run contained 320 synthetic speaker contributions and exercised token-based chunking and reduction.
The result was fully structured, in German, and preserved `Musterstadt` unchanged.

An empty `action-items` section is not a transport or structure error when the input contains no unambiguous assigned task.
One repeated run interpreted the planned future check as a task and populated the section accordingly.

### Gemma 4 26B

The existing `steno-gemma4:26b-16k` model passed the same short structure, language, and proper-name checks.
The probe took 10.4 seconds and the following structured generation took 4.7 seconds.
Ollama placed 52 percent of the 18 GB runtime model on CPU and 48 percent on GPU; the process used about 10.3 GiB of VRAM.

The 26B model is technically usable but does not fit entirely in the RTX 4070 Ti VRAM.
For interactive connection tests and routine minutes, `gemma4:12b` is the faster default.
The 26B model remains a useful quality comparison for offline runs.

## Not counted as passed

- No real meeting was sent to Ollama.
- The generic OpenAI-compatible iOS path through `/models` and `/chat/completions` was not replaced by this native Ollama test.
- LM Studio was not started; only the inactive local endpoint was observed.
- Qualitative evaluation against manually checked reference minutes remains part of the planned benchmark corpus.

## Recommendation

For the approved CachyOS machine, configure Steno with `Ollama`, the machine's local-network URL on port 11434, `gemma4:12b`, `Self-hosted`, and a 16,384-token context.
Leave the API key empty.
For later quality comparisons, select `steno-gemma4:26b-16k` when the higher latency is acceptable.
