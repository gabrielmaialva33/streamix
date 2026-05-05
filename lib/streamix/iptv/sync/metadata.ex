defmodule Streamix.Iptv.Sync.Metadata do
  @moduledoc """
  Genre and credit synchronization helpers.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Genre, Person}
  alias Streamix.Repo

  @batch_size 500

  @doc """
  Syncs genres and credits for a batch of content.
  """
  def sync_genres_and_credits(streams, provider_id, schema, genre_join_table, fk_column, opts) do
    credits_table = Keyword.fetch!(opts, :credits_table)
    stream_id_key = Keyword.get(opts, :stream_id_key, "stream_id")
    fk_col_atom = String.to_existing_atom(fk_column)
    stream_id_field = if fk_column == "series_id", do: :series_id, else: :stream_id

    db_lookup = build_db_lookup(schema, provider_id, stream_id_field)
    genre_map = streams |> extract_unique_names("genre") |> upsert_genres()
    people_map = streams |> extract_all_people() |> upsert_people()

    streams
    |> build_genre_assocs(db_lookup, genre_map, stream_id_key, fk_col_atom)
    |> batch_insert(genre_join_table)

    streams
    |> build_credit_assocs(db_lookup, people_map, stream_id_key, fk_col_atom)
    |> batch_insert(credits_table)

    :ok
  end

  defp build_db_lookup(schema, provider_id, stream_id_field) do
    schema
    |> where(provider_id: ^provider_id)
    |> select([c], {field(c, ^stream_id_field), c.id})
    |> Repo.all()
    |> Map.new()
  end

  defp extract_all_people(streams) do
    cast = extract_unique_names(streams, "cast")
    directors = extract_unique_names(streams, "director")
    MapSet.union(cast, directors)
  end

  defp build_genre_assocs(streams, db_lookup, genre_map, stream_id_key, fk_col_atom) do
    Enum.flat_map(streams, fn stream ->
      case Map.get(db_lookup, stream[stream_id_key]) do
        nil ->
          []

        db_id ->
          stream["genre"]
          |> parse_comma_separated()
          |> Enum.flat_map(&resolve_genre(&1, genre_map, fk_col_atom, db_id))
      end
    end)
  end

  defp resolve_genre(name, genre_map, fk_col_atom, db_id) do
    case Map.get(genre_map, String.downcase(name)) do
      nil -> []
      genre_id -> [%{fk_col_atom => db_id, genre_id: genre_id}]
    end
  end

  defp build_credit_assocs(streams, db_lookup, people_map, stream_id_key, fk_col_atom) do
    Enum.flat_map(streams, fn stream ->
      case Map.get(db_lookup, stream[stream_id_key]) do
        nil ->
          []

        db_id ->
          cast = build_role_credits(stream["cast"], people_map, fk_col_atom, db_id, "cast")

          dirs =
            build_role_credits(stream["director"], people_map, fk_col_atom, db_id, "director")

          cast ++ dirs
      end
    end)
  end

  defp build_role_credits(raw, people_map, fk_col_atom, db_id, role) do
    raw
    |> parse_comma_separated()
    |> Enum.with_index()
    |> Enum.flat_map(fn {name, idx} ->
      case Map.get(people_map, String.downcase(name)) do
        nil -> []
        person_id -> [%{fk_col_atom => db_id, person_id: person_id, role: role, position: idx}]
      end
    end)
  end

  defp batch_insert([], _table), do: :ok

  defp batch_insert(assocs, table) do
    assocs
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(&Repo.insert_all(table, &1, on_conflict: :nothing))
  end

  defp extract_unique_names(streams, field) do
    streams
    |> Enum.flat_map(fn stream -> parse_comma_separated(stream[field]) end)
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp parse_comma_separated(nil), do: []
  defp parse_comma_separated(""), do: []

  defp parse_comma_separated(str) when is_binary(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp upsert_genres(names) when is_struct(names, MapSet) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    entries = Enum.map(names, fn name -> %{name: name, inserted_at: now, updated_at: now} end)

    if entries != [] do
      entries
      |> Enum.chunk_every(@batch_size)
      |> Enum.each(&Repo.insert_all(Genre, &1, on_conflict: :nothing))
    end

    Genre
    |> select([g], {fragment("lower(?)", g.name), g.id})
    |> Repo.all()
    |> Map.new()
  end

  defp upsert_people(names) when is_struct(names, MapSet) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    entries = Enum.map(names, fn name -> %{name: name, inserted_at: now, updated_at: now} end)

    if entries != [] do
      entries
      |> Enum.chunk_every(@batch_size)
      |> Enum.each(&Repo.insert_all(Person, &1, on_conflict: :nothing))
    end

    Person
    |> select([p], {fragment("lower(?)", p.name), p.id})
    |> Repo.all()
    |> Map.new()
  end
end
