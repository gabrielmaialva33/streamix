defmodule Streamix.Torrent.Sources.Eztv do
  @moduledoc """
  EZTV-compatible source adapter.

  The adapter consumes a normalized JSON feed configured by
  `EZTV_SOURCE_URL`. Keeping the scraping/feed contract outside this
  module lets Streamix normalize episodes without hardcoding a brittle
  upstream HTML layout in the app.
  """

  @behaviour Streamix.Torrent.Source

  alias Streamix.Torrent.Sources.Helpers

  @slug "eztv"
  @name "EZTV"
  @rate_limit_ms 500

  @impl true
  def slug, do: @slug

  @impl true
  def name, do: @name

  @impl true
  def rate_limit_ms, do: @rate_limit_ms

  @impl true
  def fetch_listing(opts \\ []) do
    fetch_configured(opts)
  end

  defp fetch_configured(opts) do
    case Helpers.fetch_normalized_feed(@slug, opts) do
      {:error, :not_configured} -> {:ok, [], %{next_page: nil, disabled?: true}}
      result -> result
    end
  end
end
