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

The implementation lives under `Streamix.Iptv.*`. That namespace is an
implementation detail, not the application API. There is no `Streamix.Iptv`
module any more: the broad compatibility facade was retired on November 4, 2026.

## Dependency rules

1. `StreamixWeb` calls the focused boundaries and never reaches into
   `Streamix.Iptv.*`.
2. Production modules outside `lib/streamix/iptv/**` call the focused owner when
   a function/arity is already owned by a boundary.
3. A public function/arity has exactly one boundary owner. Similar names with
   different arities are still separate contracts and must be reviewed
   explicitly.
4. Boundary modules call internal modules such as `Streamix.Iptv.Movies` or
   `Streamix.Iptv.Streaming.VodProxy`.
5. Calls inside `lib/streamix/iptv/**` stay implementation-internal: an internal
   module calls another internal module, not a boundary, so no cycle appears.
6. An operation no boundary owns yet is called on its internal module, and gets
   a boundary owner before delivery code needs it.

Library operations and history-derived AI personalization take the unlocked
`scope.library_key` (API: `conn.assigns.current_library_key`). They never accept
a bare user id as authorization to read viewing data. See [privacy.md](privacy.md).

## Direction of dependencies

```text
controllers / LiveViews / workers / application services
                         |
                         v
 Catalog  Search  Library  Playback  Providers  Guide
                         |
                         v
       Streamix.Iptv.* implementation modules
```

## Examples

Use the focused owner:

```elixir
alias Streamix.{Catalog, Library, Playback, Providers}

movie = Catalog.get_public_movie(movie_id)
{:ok, favorite} = Library.add_favorite(scope.library_key, "movie", movie_id)
source = Playback.get_playable_movie(user_id, movie_id)
provider = Providers.get_provider(provider_id)
```


## Architectural tests

The following tests enforce these rules:

- `test/streamix/architecture/boundary_ownership_test.exs`
  - public contracts do not overlap;
  - the retired `Streamix.Iptv` facade does not come back.
- `test/streamix/architecture/application_boundary_consumers_test.exs`
  - production modules outside the IPTV implementation use the owner of every
    already-classified contract.
- `test/streamix/architecture/application_boundaries_test.exs`
  - every boundary call made by the web layer is exported, and every boundary
    is used by it.
- `test/streamix/architecture/context_boundaries_test.exs`
  - web and contexts reach another context only through its public module.
- `test/streamix/architecture/layer_dependencies_test.exs`
  - web code does not call `Repo` directly and domain code does not depend on
    `StreamixWeb` outside the composition root.
- `test/streamix/architecture/test_layout_test.exs`
  - one module per file, and tests mirror their source paths.

A call to a module that does not exist fails the build under
`--warnings-as-errors`, so no test has to look for calls to the retired facade.

## Adding a capability

Before adding a function:

1. Choose the boundary according to the business capability, not the table that
   stores the data.
2. Add the public function to that boundary and delegate to an internal
   implementation module.
3. Run the architecture suite and the focused domain tests.
4. Check the compile graph so the change does not add a cycle.

## Current baseline

On November 4, 2026 the compatibility facade `Streamix.Iptv` (240 delegates)
was deleted after its last callers — tests, one internal module and two
injected defaults — moved to the owning boundaries.

After the application-boundary migration on August 24, 2026:

- the web layer has no direct dependency on `Streamix.Iptv`;
- production modules outside the IPTV implementation have no direct call to the
  broad `Streamix.Iptv` facade;
- remaining IPTV references outside the implementation are explicit nested
  implementation modules used by composition or domain-specific adapters;
- the six boundary contracts have no overlapping function/arities;
- the compile graph reports one remaining cycle, confined to the Phoenix web
  layer and its compile/export macros.
