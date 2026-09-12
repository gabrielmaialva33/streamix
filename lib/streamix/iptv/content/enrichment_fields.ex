defmodule Streamix.Iptv.Content.EnrichmentFields do
  @moduledoc """
  Shared metadata ownership for provider ingestion within the IPTV context.

  Useful source metadata may replace existing values, but empty source metadata
  must not erase enrichment. Fields outside this list remain provider-owned.
  """

  import Ecto.Query

  @fields %{
    "movie" =>
      ~w(title year stream_icon rating plot duration_secs tmdb_id imdb_id youtube_trailer)a,
    "series" => ~w(title year cover rating plot youtube_trailer tmdb_id)a,
    "episode" => ~w(plot duration_secs)a
  }

  def fields(content_type), do: Map.get(@fields, content_type, [])

  # Unlike insert_all, changesets interpret explicit nil/empty values as changes.
  # Omit those keys entirely, including whitespace that Ecto casts to nil.
  def reject_blank(attrs, content_type) do
    enriched = fields(content_type)
    Map.reject(attrs, fn {key, value} -> key in enriched and blank?(key, value) end)
  end

  @doc false
  # Match the Xtream upsert's treatment of absent TMDB identifiers.
  def blank?(:tmdb_id, value) when value in [0, "0"], do: true
  def blank?(_key, nil), do: true
  def blank?(_key, value) when is_binary(value), do: String.trim(value) == ""
  def blank?(_key, _value), do: false

  @doc "Builds an atomic conflict update for the fields present in a provider row."
  def conflict_update(schema, row_fields, content_type) do
    enriched = fields(content_type)

    updates =
      Enum.map(row_fields, fn key ->
        {key, conflict_value(key, key in enriched, schema.__schema__(:type, key))}
      end)

    from(content in schema, update: [set: ^updates])
  end

  # Xtream panels also use "0" for a missing TMDB identifier.
  defp conflict_value(:tmdb_id, true, :string) do
    dynamic(
      [content],
      fragment("COALESCE(NULLIF(NULLIF(EXCLUDED.tmdb_id, ''), '0'), ?)", content.tmdb_id)
    )
  end

  defp conflict_value(key, true, :string) do
    column = Atom.to_string(key)

    dynamic(
      [content],
      fragment("COALESCE(NULLIF(EXCLUDED.?, ''), ?)", identifier(^column), field(content, ^key))
    )
  end

  # Numeric fields have already been parsed by the normalizers; empty input is
  # nil, so NULLIF against an empty string would be an invalid PostgreSQL cast.
  defp conflict_value(key, true, _type) do
    column = Atom.to_string(key)

    dynamic(
      [content],
      fragment("COALESCE(EXCLUDED.?, ?)", identifier(^column), field(content, ^key))
    )
  end

  defp conflict_value(key, false, _type) do
    column = Atom.to_string(key)
    dynamic(fragment("EXCLUDED.?", identifier(^column)))
  end
end
