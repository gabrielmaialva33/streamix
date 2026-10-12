defmodule Streamix.TestSupport.TorrentSearchSource do
  @moduledoc """
  A searchable `Streamix.Torrent.Source` for targeted-search tests.

  It searches the real GratisTorrent site profile through
  `Streamix.Torrent.Sources.HtmlScraper` (with the site forced on), so the
  requests land on the `Req.Test` stub installed by
  `Streamix.TestSupport.TorrentScraperStub.route/1`.
  """

  @behaviour Streamix.Torrent.Source

  alias Streamix.Torrent.Sources.{GratisTorrent, HtmlScraper}

  @impl true
  def slug, do: "searchable"

  @impl true
  def name, do: "Searchable (test)"

  @impl true
  def rate_limit_ms, do: 1

  @impl true
  def fetch_listing(_opts), do: {:ok, [], %{next_page: nil}}

  @impl true
  def search(wanted, opts) do
    HtmlScraper.search(%{GratisTorrent.site() | enabled: true}, wanted, opts)
  end
end
