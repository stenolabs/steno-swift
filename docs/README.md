# Documentation guide

English is the default and normative language for current Steno documentation.
German is retained only for localization, German-language speech and transcript fixtures, quoted source material, and clearly identified historical records.

## Current references

- [`../README.md`](../README.md): public-beta overview, setup, limitations, and development entry point.
- [`../ARCHITECTURE.md`](../ARCHITECTURE.md): architectural invariants, modules, data model, failure behavior, privacy boundaries, and milestones.
- [`PLAN-IOS.md`](PLAN-IOS.md): current iPhone and iPad product and implementation plan.
- [`FEATURE-PARITY.md`](FEATURE-PARITY.md): maintained legacy-to-current feature checklist.
- [`PLAN-PRIVACY.md`](PLAN-PRIVACY.md): outbound-data contract and disclosure design.
- [`LEGACY-FORMATS.md`](LEGACY-FORMATS.md): legacy import format specification.
- [`BENCH-FIXTURES.md`](BENCH-FIXTURES.md): benchmark and test-material policy.
- [`DEMO-FIXTURE.md`](DEMO-FIXTURE.md): synthetic demo-library contract.
- [`../GemmaService/README.md`](../GemmaService/README.md): isolated macOS 27 boundary and acceptance requirements for a future native Gemma 4 provider.

## Measurements

Benchmark contracts live under `benchmarks/` at the repository root.
Measured results and acceptance records live in [`benchmarks/`](benchmarks/).
Keep measurements in English even when the evaluated speech and transcript fixtures are intentionally German.

## Historical records

Selected completed reviews are retained under [`history/`](history/) for provenance.
They are non-normative and may describe code that has since changed.
Current code, tests, the architecture document, the iOS plan, the privacy contract, and the feature-parity checklist take precedence.
