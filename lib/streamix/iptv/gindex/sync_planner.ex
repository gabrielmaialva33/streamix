defmodule Streamix.Iptv.Gindex.SyncPlanner do
  @moduledoc """
  Pure module that turns a GIndex provider into a flat list of scan roots.

  A scan root is a `{base_url, path, kind}` tuple that the dispatcher hands to
  `Streamix.Workers.Gindex.ScanFolder`. `kind` is the semantic classification
  (`:movies | :series | :animes`) so downstream workers know which schema to
  write into.

  This lives separately from `Streamix.Iptv.Gindex.Sync` so the orchestration
  can evolve without dragging the legacy monolithic syncer with it.
  """

  alias Streamix.Iptv.{Provider, Providers}

  @type kind :: :movies | :series | :animes
  @type root :: %{base_url: String.t(), path: String.t(), kind: kind()}

  # Sensible defaults for the AnimeZeY provider shape: drive 1 for live-action
  # content, drive 0 for animes/animation. These are only used when no
  # `provider_drives` rows are configured.
  @default_roots [
    %{path: "/1:/Filmes/", kind: :movies},
    %{path: "/0:/Filmes/", kind: :movies},
    %{path: "/1:/Séries/", kind: :series},
    %{path: "/0:/Desenhos/", kind: :series},
    %{path: "/0:/Animes/", kind: :animes}
  ]

  @doc """
  Returns the list of scan roots for a provider. Preloads `:drives` if needed.
  """
  @spec roots_for(Provider.t()) :: [root()]
  def roots_for(%Provider{} = provider) do
    provider = Providers.preload_drives(provider)
    base_url = provider.gindex_url || provider.url

    configured =
      provider.drives
      |> Enum.map(&drive_to_root/1)
      |> Enum.reject(&is_nil/1)

    roots =
      case configured do
        [] -> @default_roots
        list -> list
      end

    Enum.map(roots, &Map.put(&1, :base_url, base_url))
  end

  defp drive_to_root(%{drive_type: kind_str, metadata: %{"path" => path}} = _drive)
       when is_binary(kind_str) and is_binary(path) and path != "" do
    case kind_atom(kind_str) do
      nil -> nil
      kind -> %{path: path, kind: kind}
    end
  end

  defp drive_to_root(_), do: nil

  defp kind_atom("movies"), do: :movies
  defp kind_atom("series"), do: :series
  defp kind_atom("animes"), do: :animes
  defp kind_atom("anime"), do: :animes
  defp kind_atom(_), do: nil
end
