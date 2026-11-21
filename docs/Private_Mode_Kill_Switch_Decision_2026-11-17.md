# Private mode becomes a cloud kill switch (2026-11-17)

**Decision.** Private mode no longer pseudonymizes. When it is on, every
cloud request refuses (`PrivateMode.checkCloudEgress` in `LLMTransport` and
the few callers that bypass it; cloud audio via `refuseCloudAudio`). When it
is off, nothing is masked. On-device work — Parakeet, Vision OCR, search,
MCP reads while off — is unchanged.

**Why.** The owner does not use private mode during development. The masked
path still taxed every cloud feature: each new caller had to go through
`LLMJSONClient` masking or `withPseudonymizedEgress`, keep one vocabulary
read per analysis, keep the depersonalized preview on the real egress path,
and keep suspect masking on. About 1 000 lines of filter/suspect/payload code
plus ~450 lines of tests existed for a mode nobody ran.

**Removed.** `PseudonymFilter`, `PseudonymSuspects`, `PseudonymizedPayload`,
`PrivateEgressPreview`, `PrivateMode.withPseudonymizedEgress`/`Egress`, the
`LLMJSONClient` privacy plumbing and prompt contract, `NoteProcessor`
private-egress preview, `wimm-cli depersonalize`, and
`PersonalGlossaryStore.analysisVocabulary` (now `analysisGlossary`).

**Kept for old data.** The glossary term flag `sensitive` still round-trips
but nothing acts on it. Sidecar key `analysisPseudonymization` is no longer
written; a new analysis clears it. Archived maps under
`Pseudonymization/maps/` are left on disk untouched.

**Bringing it back.** The full design is in `Pseudonymization_Design.md` and
`Secretary_Masked_Workspace.md` (history); the code is in git before this
decision. Re-add only with a real use case.

**Switch (2026-11-21).** Studio's menu has «Приватный режим — ничего в
облако»; it writes `privateMode` to the shared suite `group.com.wimm.app`
(`PrivateMode.setStored`), the one key Studio, the CLI, MCP and the web
server read. `WIMM_PRIVATE_MODE` still overrides it. The iPhone keeps its
own settings and has no switch yet.
