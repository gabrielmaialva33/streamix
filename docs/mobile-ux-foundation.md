# Mobile UX Foundation

- **Status:** Approved design
- **Date:** 2026-07-30
- **Primary surface:** authenticated mobile web and installed PWA

## Outcome

Make Streamix feel consistent, fast, and intentional on small screens without
turning its cinematic browsing and playback surfaces into a dashboard. The
first delivery establishes shared mobile primitives, fixes the observed
offline-sync failure, and makes the player controls predictable. Later slices
reuse the same primitives across catalog, settings, providers, and admin.

Metronic v9.5 is a visual reference for spacing, control hierarchy, form
states, status presentation, and operational screens. Its bundle, components,
and dependencies are not imported into Streamix.

## Production evidence

The design is based on an authenticated production audit of the home, browse,
search, favorites, content details, player, settings, providers, watch party,
and admin surfaces at desktop and mobile widths.

The highest-impact findings were:

- the translucent mobile navigation loses contrast over artwork and competes
  with content near the bottom edge;
- some hero, filter, card, and destructive controls are smaller than a
  reliable touch target;
- movie and series cards look clickable but their primary action is attached
  to a generic container instead of a semantic link or button;
- the player exposes a buffer-seconds badge as normal UI and lacks direct
  seek-back and seek-forward controls;
- settings mixes user preferences with technical PWA maintenance actions;
- search filters wrap and result cards become too small on narrow screens;
- admin and provider actions lose hierarchy and mix Portuguese and English;
- favorites offline sync emits an IndexedDB `DataError` because the
  `favorites` store requires an `id`, while the server payload only provides
  `content_type` and `content_id`.

## Product principles

1. **Cinematic where people browse and watch.** Artwork, motion, and dark
   surfaces remain the dominant language on home, catalog, details, and player.
2. **Operational where people configure.** Settings, providers, and admin use
   denser cards, explicit status, and restrained elevation inspired by
   Metronic.
3. **Mobile first, desktop preserved.** Shared primitives may improve desktop,
   but the first slice must not redesign the established desktop experience.
4. **One obvious primary action.** Every surface has a clear main action;
   secondary and diagnostic actions stay visually subordinate.
5. **State must be honest.** Loading, disabled, offline, failure, and selected
   states are explicit. There are no silent fallbacks that hide broken sync or
   playback behavior.

## Visual direction

### Mobile shell: solid cinematic navigation

The bottom navigation uses an almost opaque dark surface with a subtle top
border and restrained elevation. Heavy blur is removed so posters cannot
reduce label or icon contrast. It contains five equal-width destinations:
Início, Catálogo, Busca, Lista, and Perfil.

The active destination uses a compact brand-colored pill behind the icon and a
stronger label. Inactive items remain neutral. The bar includes the device safe
area, while the page reserves the exact same height so the last interactive
element is never covered.

### Card family: adaptive by content

There are two explicit card primitives:

- `poster_media_card` for movies and series, with a 2:3 image;
- `landscape_media_card` for live channels, episodes, and recent history, with
  a 16:9 image.

They share the same anatomy: media, badges, progress, title, compact metadata,
primary navigation action, and optional favorite action. The two components
remain separate instead of becoming one condition-heavy component.

The card's main area is a real link when a route is known and a real button
when the action must remain a LiveView event. The favorite action is a separate
44 px control; interactive elements are never nested.

### Player controls: standard streaming layout

The center control group is `-10 seconds`, `play/pause`, and `+10 seconds`.
The timeline, time values, volume, quality, captions, fullscreen, and other
secondary options remain below. The close action is always reachable and has a
48 px target.

Seek controls are hidden for non-seekable live playback. For seekable media,
the target time is clamped between zero and the finite duration. Existing
keyboard behavior remains available, and each visible action has an accessible
name.

The buffer-seconds badge is diagnostics-only. It may be shown when the existing
`window.__STREAMIX_DEBUG__` flag is active, but it is absent from the default
player UI. Buffering state that affects the viewer is still represented by the
normal loading indicator.

## Component architecture

### Semantic tokens

`assets/css/theme.css` owns a small set of semantic values used by the new
primitives:

- minimum touch target: 44 px;
- prominent player target: 48 px;
- mobile navigation surface, border, elevation, and height;
- selected, disabled, loading, success, warning, and destructive states;
- compact spacing steps used by mobile filters and operational cards.

Red remains the brand and selection color. Green is reserved for successful or
healthy state. Tokens extend the current theme rather than duplicating
Tailwind utilities in page-specific CSS.

### Navigation

`StreamixWeb.App.Navigation` becomes the owner of mobile navigation markup,
route-active rules, safe-area padding, and its content-reserve contract. The
main layout only decides whether authenticated mobile navigation is present.

The component exposes stable ids for LiveView and browser tests. Detail and
player routes that intentionally hide the bottom navigation also remove its
content reserve.

### Media cards

`StreamixWeb.Content.CardComponents` exposes the two card primitives and keeps
movie/series compatibility wrappers during migration. Shared private helpers
normalize title, image, metadata, progress, badges, and favorite attributes.

Callers provide the destination or event explicitly. A card never guesses a
route from incomplete content data, and failure to render an external image
continues through the existing image fallback path.

### Player

`StreamixWeb.PlayerComponents` owns the control markup and stable selectors.
The player hook owns playback effects, including the bounded seek operation.
`assets/js/player/player_ui.js` may update diagnostics but cannot create a
default-visible buffer badge.

### PWA diagnostics

Personal preferences remain visible in settings. Cache hashes, storage
details, offline refresh, and retry actions move under a collapsed
**Diagnóstico do app** section. A healthy PWA does not ask the user to reason
about caches during normal use.

## Offline favorites contract

The IndexedDB `favorites` object store keeps `keyPath: "id"`. Before a write,
the client normalizes each favorite to a stable composite key:

```text
id = "<content_type>:<content_id>"
```

`content_type` must be one of `live_channel`, `movie`, `series`, or `episode`.
`content_id` must be a positive integer or a decimal string between 1 and 19
digits; it is stored in canonical decimal form without leading zeroes. The
normalized item retains `content_type`, canonical `content_id`, display
metadata, and `synced_at`.

The full incoming snapshot is validated before opening the replacement
transaction. If any item is invalid:

- the replacement is rejected with contextual, non-sensitive diagnostics;
- the existing IndexedDB snapshot remains untouched;
- the normal UI keeps working from the last valid snapshot;
- **Diagnóstico do app** offers an explicit retry.

Once validation succeeds, clear and put operations remain in one transaction.
Transaction failure aborts the replacement and reports the store and operation,
without logging favorite titles or user data. Removal uses the same composite
key directly rather than scanning the complete store.

The server payload remains responsible for the raw `content_type` and
`content_id`; the client derives the IndexedDB key. This keeps storage-specific
identity out of the LiveView payload while still validating the browser
boundary.

## Delivery slices

### Slice 1: foundation, PWA, and player

- add semantic tokens and extract the mobile navigation component;
- enforce safe-area and content-reserve behavior at 320, 393, and 768 px;
- fix and test the offline favorites contract;
- reorganize PWA maintenance under **Diagnóstico do app**;
- add the central seek controls and hide buffer diagnostics by default.

### Slice 2: catalog and discovery

- introduce both media-card primitives and migrate home, browse, search,
  favorites, and history incrementally;
- keep mobile grids readable instead of forcing three undersized poster
  columns;
- make filter rows horizontally scrollable with a visible selected state;
- improve search empty, loading, no-result, and error states;
- make the recommended source prominent on details and collapse alternative
  sources without removing access to them.

### Slice 3: operational surfaces

- align settings and provider forms with the shared control hierarchy;
- make provider sync, disabled, healthy, and failure states explicit;
- compact mobile admin statistics and make admin navigation scrollable;
- normalize user-facing copy to pt-BR while preserving protocol and provider
  names that are proper nouns.

Each slice is independently deployable and must leave compatibility wrappers
for consumers not migrated in that slice.

## Accessibility and performance constraints

- every pointer target is at least 44 by 44 px; the primary player control and
  player close action are at least 48 by 48 px;
- all actions are reachable and understandable with keyboard-only navigation;
- focus indicators remain visible against artwork and solid surfaces;
- active navigation uses text or icon state in addition to color;
- reduced-motion preferences disable non-essential scale and movement;
- no page has horizontal overflow at 320, 393, 768, or desktop widths;
- new shell and card behavior uses CSS and existing Phoenix components, with
  no additional runtime UI framework;
- images keep lazy loading and asynchronous decoding outside the initial
  viewport;
- offline sync performs one validation pass and one atomic transaction, with
  no full-store cursor scan for removal.

## Verification contract

The implementation is complete only when all of the following pass:

- ExUnit component and LiveView tests assert stable ids, active navigation,
  semantic card actions, diagnostics disclosure, and route-specific shell
  behavior;
- JavaScript tests cover favorite normalization, invalid snapshot rejection,
  preservation of the previous snapshot, direct composite-key removal, seek
  clamping, non-seekable media, and debug-only buffer health;
- Playwright smoke tests cover authenticated mobile web and installed-PWA
  behavior at 320 and 393 px, plus one desktop regression viewport;
- automated accessibility checks find no unlabeled controls or invalid nested
  interactive elements in the changed surfaces;
- browser console output contains no `OfflineSync` warning during a successful
  favorites sync;
- `mix precommit` and the frontend test suite pass;
- production validation confirms no bottom-nav overlap, no horizontal
  overflow, persistent offline favorites, and usable player controls on a real
  mobile viewport.

## Explicit boundaries

This design does not replace Tailwind, introduce daisyUI, import Metronic,
redesign the desktop home, change provider selection policy, alter stream
token security, or change the media playback engine. Source ranking and
provider health may inform the recommended source in Slice 2, but this work
does not invent a new ranking algorithm.
