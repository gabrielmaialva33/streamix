defmodule Streamix.Gindex.ScanRootsTest do
  use Streamix.DataCase, async: true

  alias Streamix.Gindex
  alias Streamix.Iptv.Provider
  alias Streamix.Repo

  test "reconciles an unfinished cycle and only resets cursors for a new cycle" do
    provider = gindex_provider()
    roots = roots(provider.gindex_url)

    assert {:ok, first_cycle} = Gindex.ensure_scan_cycle(provider.id, roots)
    assert first_cycle.new_cycle?
    assert length(first_cycle.roots) == 2

    [movie_root, anime_root] = first_cycle.roots
    assert {:ok, movie_root} = Gindex.mark_scan_root_running(movie_root)

    checkpoint = %{
      "root_path" => movie_root.root_path,
      "category_path" => "/1:/Filmes/2026/",
      "item_path" => "/1:/Filmes/2026/B.mkv"
    }

    assert {:ok, _movie_root} = Gindex.checkpoint_scan_root(movie_root, checkpoint)

    assert {:ok, reconciled} = Gindex.ensure_scan_cycle(provider.id, Enum.reverse(roots))
    refute reconciled.new_cycle?
    assert reconciled.cycle_id == first_cycle.cycle_id
    assert Gindex.get_scan_root(provider.id, movie_root.root_path, :movies).cursor == checkpoint

    movie_root = Gindex.get_scan_root(provider.id, movie_root.root_path, :movies)
    anime_root = Gindex.get_scan_root(provider.id, anime_root.root_path, :animes)

    assert {:ok, _root} = Gindex.complete_scan_root(movie_root, %{movies_count: 2})
    assert {:ok, _root} = Gindex.fail_scan_root(anime_root, :upstream_unavailable)

    summary = Gindex.scan_cycle_summary(provider.id, first_cycle.cycle_id)
    assert summary.settled?
    assert summary.roots_completed == 1
    assert summary.roots_failed == 1

    assert {:ok, next_cycle} = Gindex.ensure_scan_cycle(provider.id, roots)
    assert next_cycle.new_cycle?
    refute next_cycle.cycle_id == first_cycle.cycle_id
    assert Enum.all?(next_cycle.roots, &(&1.status == "pending" and &1.cursor == %{}))
  end

  defp roots(base_url) do
    [
      %{base_url: base_url, path: "/1:/Filmes/", kind: :movies},
      %{base_url: base_url, path: "/0:/Animes/", kind: :animes}
    ]
  end

  defp gindex_provider do
    %Provider{}
    |> Provider.changeset(%{
      name: "GIndex Durable Roots Test",
      url: "https://gindex.example/",
      gindex_url: "https://gindex.example/",
      provider_type: :gindex,
      is_system: true,
      visibility: :global
    })
    |> Repo.insert!()
  end
end
