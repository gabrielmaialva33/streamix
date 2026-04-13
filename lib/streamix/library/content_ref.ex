defmodule Streamix.Library.ContentRef do
  @moduledoc """
  Helpers for resolving catalog_item_id from (content_type, content_id) pairs,
  and decorating favorites / watch_progress with display fields.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{CatalogItem, Episode, LiveChannel, Movie, Series}
  alias Streamix.Repo

  @favorite_types ~w(live_channel movie series episode)
  @history_types ~w(live_channel movie episode)

  @content_schemas %{
    "live_channel" => LiveChannel,
    "movie" => Movie,
    "series" => Series,
    "episode" => Episode
  }

  @spec favorite_types() :: [String.t()]
  def favorite_types, do: @favorite_types

  @spec history_types() :: [String.t()]
  def history_types, do: @history_types

  @doc """
  Given a content_type string and the content row's id, returns the catalog_item_id.
  """
  @spec resolve_catalog_item_id(String.t(), integer()) ::
          {:ok, integer()} | {:error, :invalid_content_type | :not_found}
  def resolve_catalog_item_id(content_type, content_id) do
    type = normalize_type(content_type)

    case Map.get(@content_schemas, type) do
      nil ->
        {:error, :invalid_content_type}

      schema ->
        case Repo.one(from(c in schema, where: c.id == ^content_id, select: c.catalog_item_id)) do
          nil -> {:error, :not_found}
          catalog_item_id -> {:ok, catalog_item_id}
        end
    end
  end

  @doc """
  Decorates a struct that has a preloaded `catalog_item` (with its content association)
  by extracting content_type, content_name, and content_icon.

  Works on Favorite, WatchProgress, or any struct with a `catalog_item` field.
  """
  @spec decorate(struct()) :: map()
  def decorate(%{catalog_item: %CatalogItem{} = item} = entry) do
    base = if is_struct(entry), do: Map.from_struct(entry), else: entry

    Map.merge(base, %{
      content_type: item.content_type,
      content_name: CatalogItem.content_name(item),
      content_icon: CatalogItem.content_icon(item),
      content_id: content_id_from_catalog_item(item)
    })
  end

  def decorate(entry), do: entry

  @doc """
  Extracts the concrete content row id from a catalog item.
  """
  @spec content_id_from_catalog_item(CatalogItem.t()) :: integer() | nil
  def content_id_from_catalog_item(%CatalogItem{} = item) do
    case CatalogItem.content(item) do
      nil -> nil
      content -> content.id
    end
  end

  @doc """
  Normalize id input from strings or integers.
  """
  @spec normalize_id(any()) :: {:ok, integer()} | {:error, :invalid_content_id}
  def normalize_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  def normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {normalized_id, ""} when normalized_id > 0 -> {:ok, normalized_id}
      _ -> {:error, :invalid_content_id}
    end
  end

  def normalize_id(_id), do: {:error, :invalid_content_id}

  defp normalize_type(type) when is_binary(type), do: type
  defp normalize_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalize_type(_type), do: nil
end
