defmodule Streamix.Iptv.Sync.ContentUpsertPreservationTest do
  use Streamix.DataCase, async: true

  import Streamix.IptvFixtures

  alias Streamix.Iptv.{LiveChannel, Movie, Series}
  alias Streamix.Iptv.Sync.ContentUpsert
  alias Streamix.Iptv.Sync.Normalizers.LiveChannel, as: ChannelNormalizer
  alias Streamix.Iptv.Sync.Normalizers.Movie, as: MovieNormalizer
  alias Streamix.Iptv.Sync.Normalizers.Series, as: SeriesNormalizer
  alias Streamix.Repo

  # List syncs must preserve both omitted enrichment columns and metadata that
  # a panel includes with blank values. Otherwise surviving stamps block repair.
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

    # Provider-owned values continue to update.
    assert reloaded.name == "Título Novo"

    # Empty list metadata must not erase enriched values.
    assert reloaded.plot == "Sinopse vinda do TMDB."
    assert reloaded.tmdb_id == "550"

    # Everything else is enrichment and survives.
    assert reloaded.tagline == "Uma tagline."
    assert reloaded.content_rating == "14"
    assert reloaded.tmdb_searched_at == stamped_at
    assert reloaded.tmdb_details_at == stamped_at
    assert reloaded.track_metadata == %{"audio" => [], "subtitle" => []}
  end

  for {kind, schema, normalizer, fixture, id_field, artwork} <- [
        {"movie", Movie, MovieNormalizer, :movie_fixture, :stream_id, :stream_icon},
        {"series", Series, SeriesNormalizer, :series_content_fixture, :series_id, :cover}
      ] do
    test "#{kind} metadata can be filled and refreshed, but never erased by blank list values", %{
      provider: provider
    } do
      schema = unquote(schema)
      normalizer = unquote(normalizer)
      id_field = unquote(id_field)
      artwork = unquote(artwork)

      metadata = %{
        title: "Título enriquecido",
        year: 1999,
        rating: Decimal.new("8.5"),
        plot: "Sinopse enriquecida",
        tmdb_id: "550",
        youtube_trailer: "trailer-id"
      }

      metadata = Map.put(metadata, artwork, "https://images.example.com/poster.jpg")

      metadata = Map.merge(metadata, extra_metadata(schema))

      empty = Map.new(metadata, fn {key, _value} -> {key, nil} end)

      record =
        apply(Streamix.IptvFixtures, unquote(fixture), [provider, Map.put(empty, id_field, 6161)])

      payload =
        Map.new(metadata, fn {key, value} ->
          {Atom.to_string(key), if(key == :rating, do: "8.5", else: value)}
        end)

      payload = Map.merge(payload, %{Atom.to_string(id_field) => 6161, "name" => "Provider name"})

      sync([payload], provider, schema, normalizer, id_field, unquote(kind))
      assert Map.take(Repo.get!(schema, record.id), Map.keys(metadata)) == metadata

      # Useful upstream metadata still replaces prior values (EXCLUDED first).
      sync(
        [Map.put(payload, "plot", "Sinopse atualizada")],
        provider,
        schema,
        normalizer,
        id_field,
        unquote(kind)
      )

      metadata = Map.put(metadata, :plot, "Sinopse atualizada")

      for blank <- [nil, "", "0"] do
        blank_metadata =
          Map.new(metadata, fn {key, _value} ->
            value =
              cond do
                key == :tmdb_id -> blank
                key == :duration_secs -> nil
                blank == "0" -> ""
                true -> blank
              end

            {Atom.to_string(key), value}
          end)

        incoming =
          Map.merge(blank_metadata, %{
            Atom.to_string(id_field) => 6161,
            "name" => "Renamed provider title",
            "container_extension" => ""
          })

        sync([incoming], provider, schema, normalizer, id_field, unquote(kind))
        reloaded = Repo.get!(schema, record.id)
        assert Map.take(reloaded, Map.keys(metadata)) == metadata
        assert reloaded.name == "Renamed provider title"
        assert reloaded.catalog_item_id == record.catalog_item_id
        assert reloaded.inserted_at == record.inserted_at
        assert_provider_fields(reloaded)
      end
    end
  end

  test "live-channel fields remain provider-owned, including empty values", %{provider: provider} do
    channel =
      channel_fixture(provider, %{
        direct_source: "https://media.example.com/live",
        tv_archive: true
      })

    payload = %{
      "stream_id" => channel.stream_id,
      "name" => "New channel",
      "stream_icon" => "",
      "epg_channel_id" => nil,
      "direct_source" => "",
      "tv_archive" => 0
    }

    sync([payload], provider, LiveChannel, ChannelNormalizer, :stream_id, "live_channel")
    reloaded = Repo.get!(LiveChannel, channel.id)
    assert reloaded.name == "New channel"
    assert reloaded.stream_icon == ""
    assert reloaded.epg_channel_id == nil
    assert reloaded.direct_source == ""
    refute reloaded.tv_archive
  end

  defp extra_metadata(Movie), do: %{duration_secs: 7200, imdb_id: "tt0137523"}
  defp extra_metadata(Series), do: %{}

  defp assert_provider_fields(%Movie{} = movie), do: assert(movie.container_extension == "")
  defp assert_provider_fields(%Series{}), do: :ok

  defp sync(payload, provider, schema, normalizer, id_field, kind) do
    ContentUpsert.upsert_batched(payload, provider.id, %{}, DateTime.utc_now(:second),
      schema: schema,
      stream_id_field: id_field,
      content_type: kind,
      attrs_fn: &normalizer.attrs/3,
      category_fn: fn _batch, _returned, _lookup -> [] end
    )
  end
end
