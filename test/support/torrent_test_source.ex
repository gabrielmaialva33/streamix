defmodule Streamix.TestSupport.TorrentTestSource do
  @moduledoc """
  In-memory implementation of `Streamix.Torrent.Source` used by
  the orchestrator unit tests.

  Pages and items are seeded via the application env at
  `:streamix, :torrent_test_source` so each test can hand-roll its own
  scenario without HTTP, fixtures, or `Mox` overhead.

      Application.put_env(:streamix, :torrent_test_source, [
        {1, [item1, item2], %{next_page: 2}},
        {2, [item3], %{next_page: nil}}
      ])
  """

  @behaviour Streamix.Torrent.Source

  @impl true
  def slug, do: "test"

  @impl true
  def name, do: "Test Source"

  @impl true
  def rate_limit_ms, do: 1

  @impl true
  def fetch_listing(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    pages = Application.get_env(:streamix, :torrent_test_source, [])

    case Enum.find(pages, fn {p, _items, _meta} -> p == page end) do
      {^page, items, meta} -> {:ok, items, meta}
      nil -> {:ok, [], %{next_page: nil}}
    end
  end
end
