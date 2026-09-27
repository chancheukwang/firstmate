---
name: two-pass-coding
description: Load before scoping an authorized coding ship when this Firstmate home's data/captain.md explicitly requests /implement followed by no-mistakes validate-only as two independent review passes.
user-invocable: false
metadata:
  internal: true
---

# Two-pass coding preference

This procedure applies only while this home's explicit captain preference calls for it, across that home's projects.
It does not turn a scout, knowledge-only review, documentation-only task, or unapproved implementation into a coding ship.
It does not change another home's defaults, the project's delivery posture, ask-user authority, or merge authority.

Before dispatch, include the preference in the worker's task-specific instructions and establish that the selected worker can obtain a genuinely independent first code review and the project has a complete no-mistakes delivery path.
If the selected project cannot use that path, or the worker cannot secure an independent reviewer, stop and ask firstmate to obtain specific captain direction rather than skipping either pass, inventing a remote, changing another project, or merging.
Do not claim that every worker runtime has a literal `/implement` slash command.

For an authorized coding change, instruct the worker to follow the accessible `/implement` recipe when available or this portable equivalent when it is not: implement the accepted task, use test-driven development where possible at agreed seams, typecheck and run focused tests regularly, run the full test suite once at the end, and obtain a separate code review of the diff against a fixed base before committing.
The first review must be by a reviewer independent of the implementer, cover both the project's documented standards and the accepted specification, report findings, and have applicable defects resolved and rechecked before the implementation commit.
Where `/code-review` is accessible, use its independent-review procedure; otherwise use an available independent reviewer with the same two review axes, not the implementer's own self-review.
Do not add a third manual reviewer.

After that commit, the same worker invokes no-mistakes in validate-only mode on the committed branch head, as a deliberate second independent review and its broader delivery checks.
The no-mistakes pipeline alone owns its findings, fixes, documentation, push, PR, and CI after it starts; a pipeline fix may advance the head under its own custody.
Follow the selected no-mistakes path and the worker-side intent contract in `../../../bin/fm-dod-lib.sh`, with `validation-supervision` owning supervision and ask-user escalation.
No review or validation pass grants permission to merge; the captain alone approves merging under this home's explicit preference.
