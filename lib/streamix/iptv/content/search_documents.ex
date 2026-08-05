defmodule Streamix.Iptv.SearchDocuments do
  @moduledoc """
  Read projection used by search indexers.

  The projection keeps IPTV persistence and schema knowledge inside this
  context while exposing only the fields needed to build search documents.
  """

  import Ecto.Query, warn: false

  alias Streamix.Helpers
  alias Streamix.Iptv.{Movie, Provider, Series}
  alias Streamix.Repo

  @type kind :: :movies | :series

  @spec list(kind(), integer() | nil, keyword()) :: [map()]
  def list(kind, provider_id \\ nil, opts \\ [])
      when kind in [:movies, :series] and (is_nil(provider_id) or is_integer(provider_id)) and
             is_list(opts) do
    after_id = Keyword.get(opts, :after_id, 0)

    unless is_integer(after_id) and after_id >= 0 do
      raise ArgumentError, "expected :after_id to be a non-negative integer"
    end

    kind
    |> schema_for()
    |> base_query(after_id)
    |> maybe_filter_provider(provider_id)
    |> Repo.all()
    |> Enum.map(&to_document/1)
  end

  defp schema_for(:movies), do: Movie
  defp schema_for(:series), do: Series

  defp base_query(schema, after_id) do
    from(content in schema,
      as: :content,
      join: provider in Provider,
      as: :provider,
      on: provider.id == content.provider_id,
      where: not is_nil(content.title) and content.id > ^after_id,
      where: provider.is_active == true,
      order_by: [asc: content.id],
      preload: [:genres]
    )
  end

  defp maybe_filter_provider(query, nil), do: query

  defp maybe_filter_provider(query, provider_id) do
    from([content: content] in query, where: content.provider_id == ^provider_id)
  end

  defp to_document(content) do
    %{
      id: content.id,
      title: content.title,
      plot: content.plot,
      year: content.year,
      genres: Helpers.genre_names(content.genres),
      rating: content.rating,
      provider_id: content.provider_id
    }
  end
end
