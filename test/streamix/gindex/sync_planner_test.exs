defmodule Streamix.Gindex.SyncPlannerTest do
  use Streamix.DataCase, async: true

  alias Streamix.Gindex.SyncPlanner
  alias Streamix.Iptv.{Provider, ProviderDrive}
  alias Streamix.Repo

  defp gindex_provider(attrs \\ %{}) do
    base = %{
      name: "GIndex Test",
      url: "https://gindex.example/",
      gindex_url: "https://gindex.example/",
      provider_type: :gindex,
      is_system: true,
      visibility: :global
    }

    %Provider{}
    |> Provider.changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  defp add_drive(provider, type, path, name \\ nil) do
    %ProviderDrive{}
    |> ProviderDrive.changeset(%{
      provider_id: provider.id,
      name: name || "#{type} root",
      drive_type: type,
      metadata: %{"path" => path}
    })
    |> Repo.insert!()
  end

  describe "roots_for/1 with no drives configured" do
    test "falls back to the baked-in AnimeZeY path layout" do
      provider = gindex_provider()
      roots = SyncPlanner.roots_for(provider)

      # Defaults cover drive 0 (animes/desenhos/filmes) and drive 1
      # (filmes/séries), ensuring we don't miss an entire half of the catalog
      # when nobody set up drives explicitly.
      kinds = Enum.map(roots, & &1.kind) |> Enum.uniq() |> Enum.sort()
      assert kinds == [:animes, :movies, :series]

      series_paths =
        roots
        |> Enum.filter(&(&1.kind == :series))
        |> Enum.map(& &1.path)

      assert "/1:/Séries/Séries WEB-DL/" in series_paths
      assert "/1:/Séries/Séries Misturado/" in series_paths
      refute "/1:/Séries/" in series_paths
      assert Enum.all?(roots, &(&1.base_url == provider.gindex_url))
    end

    test "rotates the first root by UTC day so one catalog kind cannot starve forever" do
      provider = gindex_provider()

      day_one = SyncPlanner.roots_for(provider, ~D[2026-01-01])
      day_two = SyncPlanner.roots_for(provider, ~D[2026-01-02])

      assert Enum.map(day_two, & &1.path) ==
               Enum.map(tl(day_one) ++ [hd(day_one)], & &1.path)
    end
  end

  describe "roots_for/1 with configured drives" do
    test "honors provider_drives rows and ignores defaults" do
      provider = gindex_provider()
      add_drive(provider, "movies", "/1:/Filmes/")
      add_drive(provider, "series", "/1:/Séries/")

      roots = SyncPlanner.roots_for(provider)

      assert length(roots) == 2
      assert %{kind: :movies, path: "/1:/Filmes/"} = Enum.find(roots, &(&1.kind == :movies))
      assert %{kind: :series, path: "/1:/Séries/"} = Enum.find(roots, &(&1.kind == :series))
    end

    test "skips drives with unknown types instead of crashing" do
      provider = gindex_provider()
      add_drive(provider, "livros", "/1:/Livros/")
      add_drive(provider, "movies", "/0:/Filmes/")

      roots = SyncPlanner.roots_for(provider)
      assert length(roots) == 1
      assert hd(roots).kind == :movies
    end

    test "expands a configured paths list into independent scan roots" do
      provider = gindex_provider()

      %ProviderDrive{}
      |> ProviderDrive.changeset(%{
        provider_id: provider.id,
        name: "series roots",
        drive_type: "series",
        metadata: %{
          "paths" => [
            "/1:/Séries/Séries WEB-DL/",
            "/1:/Séries/Séries Misturado/"
          ]
        }
      })
      |> Repo.insert!()

      roots = SyncPlanner.roots_for(provider)

      assert Enum.map(roots, & &1.path) |> Enum.sort() ==
               ["/1:/Séries/Séries Misturado/", "/1:/Séries/Séries WEB-DL/"]
    end

    test "skips drives that have no path in metadata" do
      provider = gindex_provider()

      %ProviderDrive{}
      |> ProviderDrive.changeset(%{
        provider_id: provider.id,
        name: "broken",
        drive_type: "movies",
        metadata: %{}
      })
      |> Repo.insert!()

      # Zero valid drives => falls back to defaults rather than returning [].
      roots = SyncPlanner.roots_for(provider)
      refute Enum.empty?(roots)
    end
  end
end
