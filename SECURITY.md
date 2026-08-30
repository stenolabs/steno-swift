# Security policy

## Supported versions

Steno is currently a source-only public beta.
Security fixes are made on the latest commit of the `main` branch.
Older commits, local modifications, and Steno Legacy are not supported by this repository.

## Reporting a vulnerability

Please do not disclose a suspected vulnerability in a public issue or discussion.

Use **Security > Advisories > Report a vulnerability** in this GitHub repository.
This sends the report privately to the repository maintainers.

If the private reporting button is unavailable, open a public issue that says only that you need a private security contact.
Do not include the vulnerability, exploit, logs, file paths, meeting metadata, or other sensitive details in that issue.

Include as much of the following as you safely can in the private report:

- the affected commit and Apple platform;
- the security impact and conditions required to trigger it;
- minimal reproduction steps using synthetic or otherwise non-sensitive data;
- whether recording integrity, local meeting data, credentials, or an external endpoint is affected; and
- any suggested mitigation or fix.

Never attach real recordings, transcripts, participant details, API keys, tokens, or other private meeting data.
Use Steno's bundled synthetic demo meetings or a minimal generated fixture whenever possible.

## What to expect

The maintainers will triage the report privately and coordinate any fix and disclosure through the GitHub security advisory.
Response and remediation time depend on severity and maintainer availability; this beta does not promise a fixed service-level agreement.

Please allow a reasonable period for investigation and remediation before public disclosure.

## Scope

Reports are especially useful when they concern:

- loss, corruption, or unintended replacement of original recordings;
- unintended disclosure of recordings, transcripts, speaker identities, notes, reports, or API credentials;
- network requests that bypass Steno's explicit external-report boundary;
- unsafe handling of imported or transferred meeting packages; or
- a way to bypass integrity, provenance, consent, or human-confirmation safeguards.

General bugs, feature requests, and expected limitations documented in the README belong in the public issue tracker.
