# Work package: data classes and what may leave the device

Product proposal from 6 August 2026: provide one place in Settings that explains what may be sent to the cloud and what must remain on device.
An independent architecture review by Fable was requested because this is a security-relevant design.
Its recommendation and reasoning are incorporated here.

## Motivation

Steno is local-first.
Content can leave the device only through two distinct, explicitly confirmed actions: generating minutes with an external language model, or exporting one meeting package through the local system share flow.
Audio is excluded from the model path.
It enters a meeting package only when the user explicitly enables audio for that one local transfer.
Audio is never transmitted automatically, for cloud sync, or to a model.
A `.stenomeeting` package is unencrypted, and although the system share flow prompts the user to select AirDrop, it cannot technically guarantee an AirDrop-only transport.

Five individually justified rules had accumulated in five code locations without a visible common policy.
This document defines that policy.

## Decision: one registry, not a switchboard

**Provide one place, with no global toggles.**
The two real decisions remain at the moment of action: model choice for each report run, and local export of one meeting package with explicit audio inclusion for that transfer.
The model path and package path share neither a global switch nor an allowlist.

The reason is not convenience but the narrow decision space.
Email addresses are never allowed, third-party documents are never allowed, sending a transcript is the purpose of choosing an external model, and notes are the context channel without which external rendering is worse than local rendering.
A switchboard would contain controls that either must not change the decision or would make the feature useless when disabled.
Each would also become a set-and-forget promise that nobody rechecks at transmission time.

Users need visibility, not configuration: a registry that displays the rules rather than setting them.

## Data classes

**Never leave the device through a model or automatic path, without exception:**

- Audio recordings are transcribed on device and are never sent to a model or cloud sync.
  The only exception is a user-confirmed local transfer of one meeting package for which audio was explicitly enabled.
- Email addresses attached to people, already enforced by code and tests.
- Third-party documents: PDF full text and text extracted by Vision OCR from pasted images.
  These are one class with one boundary.
- API keys, stored in Keychain.
- **Everything undeclared is denied by default.**
  A class absent from the manifest cannot leave the device.
  This is the most important hard rule because it covers future classes.

## Local storage for model endpoints

The endpoint list and its recovery journal live in a secret-free registry file at `Application Support/Steno/TextModelEndpoints/registry-state.json`.
It contains only visible configuration such as name, URL, model identifier, whether a key is required, and configuration revision.
API keys remain exclusively in revision-bound Keychain slots and never enter the registry file, UserDefaults, jobs, or journals.
The registry file and directory are readable only by the local user, and the directory is excluded from system backup.
After device-backup restoration, public endpoint configuration may therefore need to be set up again.
Existing UserDefaults configuration is removed only after the atomically written registry has been read back and verified.

**Included if and only if an external model is selected for this run:**

- Transcript with confirmed speaker names.
- Participant names and companies.
- The user's meeting notes.

**Included if and only if the user initiates local export of this particular meeting package:**

- The user's notes and time markers.
- The portable transcript with confirmed visible speaker names and generic speaker labels.
- Audio only when explicitly enabled locally for this one transfer.

The meeting-package allowlist excludes participant lists, the people library, email addresses, embeddings, review and diarization runs, reports, and folder assignments.

Company and notes could theoretically be optional on the model path, but they remain fixed and disclosed.
If a real need arises, such as notes containing private asides, the opt-out belongs next to the transmission notice at render time, never in Settings.
The same applies if PDF content is ever allowed externally: that would be a new per-action consent decision and would explicitly override the boundary in `PLAN-CONTEXT.md` step 4.

## Where each decision belongs

**Settings is the registry.**
Keep the registry in language-model settings above the endpoint list because that is where the external model path is configured, while the distinct package rule must remain visible beside it.
A separate privacy page would be overlooked.
Use two columns and no interaction.

**The moment of action is the decision.**
Before report generation, show the exact classes included in that model run.
Do not maintain this notice by hand; derive it from the same source as the prompt payload.
Meeting export is a separate action with its own package allowlist and an explicit audio choice for that transfer.

One honesty limit remains: the notice names classes at display time.
If the user edits notes between seeing the notice and clicking, the run includes the updated notes.
This is acceptable because the notice describes classes, not their current contents.

## Keeping disclosure and behavior coupled

This is the core requirement.
A privacy notice that lies is worse than no notice.

**Structure: providers remain blind to the library.**
`OpenAICompatibleProvider` has no Library reference and sees only its explicit input.
Treat this as an invariant: an external provider never receives a `Library`, `LibraryLayout`, or store.
The external model path therefore has exactly one outbound-data choke point, `executeTemplateRender` in `PipelineCoordinator`.
New context reaches the prompt only as a new field on `RenderContext`.

**Derivation: disclosure is a function of the payload, not a second ledger.**
A `PromptDataClass` enum conforming to `CaseIterable` is the manifest, with policy and user-facing name for every class.
`OutboundDisclosure.classes(transcript:participants:context:)` returns the outbound classes actually present in the run.
The notice is formatted from that result.

**Three types of tests:**

1. **Sentinel test, the strongest.**
   A fixture library gives every class a unique marker.
   A recording mock provider captures the entire render request.
   Forbidden sentinels must appear nowhere the provider can observe, allowed sentinels must appear, and `OutboundDisclosure` must report exactly the sentinels found.
   This tests lying in both directions: the notice may neither omit nor overstate data.
2. **Mirror tripwire.**
   Compare the stored properties of `RenderContext` against a known list.
   Adding a field breaks the test with a message explaining the required review.
   This catches the most dangerous failure: silent expansion.
3. **Compiler enforcement.**
   `PromptDataClass` is `CaseIterable`, while disclosure and policy use exhaustive switches.
   A new class without a policy decision does not compile.

No layer can prevent text derived from third-party documents, such as PDF extraction or image OCR, from being copied into a field classified as allowed, such as `userNotes`.
That tempting implementation would bypass the PDF boundary.
The associated sentinel test must be added with the image feature.

## User-facing language

- "Audio recordings" - "Stay on this device unless you explicitly include them in one meeting transfer."
- "Transcript with speaker names" - "Sent with the minutes when you choose an external model; a portable transcript with confirmed visible names and generic labels is also included in a meeting package."
- "Participants: names and companies" - "Sent only with the minutes when you choose an external model, never in a meeting package."
- "Your meeting notes" - "Sent with the minutes when you choose an external model and included when you export one meeting package."
- "Email addresses" - "Never included, they only organize your speaker library."
- "Documents and pasted images" - "Used on this Mac to improve recognition, never sent."

Avoid implementation terms such as `RenderContext` and "prompt", as well as vague labels such as "metadata".
Each row names something the user has handled directly.

## Status

Done: the pre-generation notice now names participant lists and notes when present, not just the transcript, and states what stays local.
This was the most urgent issue because the notice became inaccurate after notes and companies were added.

Open: implement the `PromptDataClass` manifest, derive `OutboundDisclosure` from the shared source used for payload construction, add the Settings registry, and add all three test types.
