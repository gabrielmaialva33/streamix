# Phoenix, LiveView and Ecto guidance

[AGENTS.md](../AGENTS.md) is the authoritative repository policy. This guide explains how to apply it; it does not
introduce a second set of rules.

## Delivery and application boundaries

Controllers, LiveViews and jobs call the public contexts described in
[application-boundaries.md](application-boundaries.md). Keep provider schemas and transport implementation out of the
web layer. Read personal library data with the unlocked library key, not a user id alone; see
[privacy.md](privacy.md). Authorization belongs before loading or exposing private content.

A LiveView uses `@current_scope.user`, receives its layout through `live_session`, and uses streams for growing lists.
Load route-dependent state in `handle_params/3`; a patch can change filters without mounting again. Reset pagination
and streams when the filter changes. Keep event handlers concerned with presentation and call a context for domain
operations. Use a function component for shared stateless markup; introduce LiveComponents only for real state or reuse.

## Templates and browser lifecycle

Use HEEx with `{...}` attributes, `<%= ... %>` for blocks, `<.link navigate={...}>` for navigation and
`<.link patch={...}>` for filter changes. Stable DOM ids let tests assert structure without depending on incidental text.
Read and write return paths through `StreamixWeb.ReturnPath`. Never put upstream stream URLs in browser data attributes
outside the explicitly documented authorized direct-playback flow.

Hooks own their listeners, observers and timers and release them on destroy. Reuse the cancellation and focus helpers
instead of adding another lifecycle implementation. Browser conventions live in [assets/README.md](../assets/README.md),
with player-specific details in [player-architecture.md](player-architecture.md). Colors use the dark theme tokens;
keyboard focus and reduced-motion behavior are part of a component's contract.

## Persistence and external effects

Generate migrations with `mix ecto.gen.migration`. Programmatic ownership fields are assigned explicitly rather than
cast from untrusted parameters. Use changeset accessors to inspect changed values. Preload the associations that a
serializer will access and apply eligibility filters before pagination. Check a query plan before adding an index.
Timescale hypertables and retention changes require their own data migration and rollback review.

Use Req through the owning context's client for HTTP, with explicit timeout/retry budgets. Log a constant message and
sanitized metadata; register new metadata keys in `config/config.exs`. Runtime environment parsing belongs in
`config/runtime.exs` and the designated configuration reader. Avoid generating atoms from input.

## Validation

Regression tests exercise the behavior through the appropriate context, controller or LiveView. Supervise processes
started by tests and synchronize with messages/monitors rather than sleeps. Mirror source paths under `test/`.
[CONTRIBUTING.md](../CONTRIBUTING.md) and [AGENTS.md](../AGENTS.md) list the standard checks. API changes must also pass
OpenAPI generation and lint, as described in [api-v1.md](api-v1.md). Tests must use a database whose name ends in `_test`;
the runtime guard rejects unsafe destinations. Browser E2E is a separate gate from Node unit tests.
