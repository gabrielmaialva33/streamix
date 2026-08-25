# Application boundaries

Streamix uses focused application boundaries between delivery code and the
historical IPTV implementation. These modules express product capabilities;
they are not alternate namespaces for schemas or repositories.

## Boundaries

| Boundary | Owns |
| --- | --- |
| `Streamix.Catalog` | Catalog browsing, movies, series, episodes, channels, categories, shelves, GIndex views, assets, and canonical catalog identity |
| `Streamix.Search` | Search, autocomplete, suggestions, semantic discovery, and provider-scoped search queries |
| `Streamix.Library` | Favorites, watch history, playback progress, and the personalization refresh caused by library writes |
| `Streamix.Playback` | Playability checks, source selection, failover ordering, stream URL resolution, proxy delivery, and stream error normalization |
| `Streamix.Providers` | Provider lifecycle, visibility, health, synthetic providers, sync state, and provider-specific source configuration |
| `Streamix.Guide` | EPG synchronization, channel schedules, current/next programs, and guide queries |

The implementation may still live under `Streamix.Iptv.*` while it is extracted.
That namespace is an implementation detail, not the application API.

## Dependency rules

1. `StreamixWeb` calls the focused boundaries and never calls `Streamix.Iptv`
   directly.
2. Production modules outside `lib/streamix/iptv/**` call the focused owner when
   a function/arity is already owned by a boundary.
3. A public function/arity has exactly one boundary owner. Similar names with
   different arities are still separate contracts and must be reviewed
   explicitly.
4. Boundary modules may call internal modules such as `Streamix.Iptv.Movies` or
   `Streamix.Iptv.Streaming.VodProxy`; they must never route through the broad
   `Streamix.Iptv` facade.
5. `Streamix.Iptv` is a compatibility facade. For an owned contract, it only
   delegates to the owning boundary; new business logic must not be added there.
6. Calls inside `lib/streamix/iptv/**` may remain implementation-internal. Moving
   them through an application boundary is optional and must not introduce a
   dependency cycle.
7. A legacy operation without a boundary owner may remain on `Streamix.Iptv`
   temporarily. It must be classified before delivery or orchestration code is
   migrated.

## Direction of dependencies

```text
controllers / LiveViews / workers / application services
                         |
                         v
 Catalog  Search  Library  Playback  Providers  Guide
                         |
                         v
       Streamix.Iptv.* implementation modules

 Streamix.Iptv compatibility facade
                         |
                         v
              owning application boundary
```

The compatibility arrow deliberately points toward the boundary. A boundary
pointing back to `Streamix.Iptv` would create an architectural loop and is
rejected by tests.

## Examples

Use the focused owner:

```elixir
alias Streamix.{Catalog, Library, Playback, Providers}

movie = Catalog.get_public_movie(movie_id)
{:ok, favorite} = Library.add_favorite(user_id, "movie", movie_id)
source = Playback.get_playable_movie(user_id, movie_id)
provider = Providers.get_provider(provider_id)
```

Do not use the broad facade in new production code:

```elixir
# Avoid
Streamix.Iptv.get_public_movie(movie_id)
```

The compatibility facade remains valid only for callers not migrated yet and
for external code that must preserve the existing API.

## Architectural tests

The following tests enforce these rules:

- `test/streamix/architecture/boundary_ownership_test.exs`
  - boundaries do not depend on the broad facade;
  - public contracts do not overlap;
  - the compatibility facade preserves every owned arity;
  - owned facade functions route to the correct boundary.
- `test/streamix/architecture/application_boundary_consumers_test.exs`
  - production modules outside the IPTV implementation use the owner of every
    already-classified contract.
- `test/streamix/architecture/application_boundaries_test.exs`
  - the web layer uses focused boundaries instead of the broad facade.
- `test/streamix/architecture_boundaries_test.exs`
  - web code does not call `Repo` directly and domain code does not depend on
    `StreamixWeb` outside the composition root.

## Adding a capability

Before adding a function:

1. Choose the boundary according to the business capability, not the table that
   stores the data.
2. Add the public function to that boundary and delegate to an internal
   implementation module.
3. Add or preserve the compatibility delegate in `Streamix.Iptv` when the old
   API must remain stable.
4. Migrate delivery and orchestration callers to the boundary.
5. Run the architecture suite and the focused domain tests.
6. Check the compile graph so the change does not add a cycle.

## Current baseline

After the application-boundary migration on August 24, 2026:

- the web layer has no direct dependency on `Streamix.Iptv`;
- production modules outside the IPTV implementation have no direct call to the
  broad `Streamix.Iptv` facade;
- remaining IPTV references outside the implementation are explicit nested
  implementation modules used by composition or domain-specific adapters;
- the six boundary contracts have no overlapping function/arities;
- the compile graph reports one remaining cycle, confined to the Phoenix web
  layer and its compile/export macros.
