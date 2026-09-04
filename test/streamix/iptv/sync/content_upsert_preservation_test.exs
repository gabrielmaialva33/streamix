defmodule Streamix.Iptv.Sync.ContentUpsertPreservationTest do
  use Streamix.DataCase, async: true

  import Streamix.IptvFixtures

  alias Streamix.Iptv.Movie
  alias Streamix.Iptv.Sync.ContentUpsert
  alias Streamix.Iptv.Sync.Normalizers.Movie, as: MovieNormalizer
  alias Streamix.Repo

  # Movies, live channels and series all upsert through this module. Under
  # `:replace_all_except` every column the normalizer does not produce was
  # written as `EXCLUDED.col` — the column default — so a six-hour sync nulled
  # `tagline`, `content_rating`, `track_metadata`, the gindex URL cache, and the
  # TMDB bookkeeping. The last one is the expensive part: resetting
  # `tmdb_searched_at` and `tmdb_details_at` makes the nightly enrichment
  # workers redo the whole catalog on every cycle, forever.
  setup do
    provider = global_provider_fixture(%{provider_type: :xtream})
    %{provider: provider}
  end

  test "a sync keeps every column its payload has no opinion about", %{provider: provider} do
    movie =
      movie_fixture(provider, %{
        stream_id: 5150,
        name: "Título Antigo",
        plot: "Sinopse vinda do TMDB.",
        tagline: "Uma tagline.",
        content_rating: "14",
        tmdb_id: "550"
      })

    stamped_at = DateTime.utc_now(:second)

    Repo.update_all(from(m in Movie, where: m.id == ^movie.id),
      set: [
        tmdb_searched_at: stamped_at,
        tmdb_details_at: stamped_at,
        track_metadata: %{"audio" => [], "subtitle" => []}
      ]
    )

    # What the xtream VOD list actually returns for this catalog: the fields
    # exist and are empty.
    upstream = [
      %{
        "stream_id" => 5150,
        "name" => "Título Novo",
        "plot" => "",
        "rating" => "0",
        "tmdb_id" => "0"
      }
    ]

    {count, _ids} =
      ContentUpsert.upsert_batched(upstream, provider.id, %{}, DateTime.utc_now(:second),
        schema: Movie,
        stream_id_field: :stream_id,
        content_type: "movie",
        attrs_fn: &MovieNormalizer.attrs/3,
        category_fn: fn _batch, _returned, _lookup -> [] end
      )

    assert count == 1

    reloaded = Repo.get!(Movie, movie.id)

    # The payload owns these and replaces them, empty values included.
    assert reloaded.name == "Título Novo"

    # Everything else is enrichment and survives.
    assert reloaded.tagline == "Uma tagline."
    assert reloaded.content_rating == "14"
    assert reloaded.tmdb_searched_at == stamped_at
    assert reloaded.tmdb_details_at == stamped_at
    assert reloaded.track_metadata == %{"audio" => [], "subtitle" => []}
  end
end
