defmodule Streamix.Queue.SyncTaskTest do
  use ExUnit.Case, async: true

  alias Streamix.Queue.SyncTask

  defmodule IptvStub do
    def get_provider(id) when id in [7, 8], do: %{id: id}
    def get_provider(_id), do: nil

    def sync_provider_section(%{id: 8}, _section), do: {:error, :not_xtream_provider}

    def sync_provider_section(%{id: 7}, section) do
      send(self(), {:iptv_section, section})

      counts = %{categories: 3, live: 5, movies: 7, series: 11}
      {:ok, Map.fetch!(counts, section)}
    end
  end

  defmodule FailingIptvStub do
    def get_provider(7), do: %{id: 7}

    def sync_provider_section(%{id: 7}, :movies),
      do: {:error, {:vod_sync_failed, :timeout}}
  end

  defmodule GindexStub do
    def sync_provider(provider) do
      send(self(), {:gindex_provider, provider.id})
      {:ok, %{movies_count: 13}}
    end

    def sync_path(provider, path, kind) do
      send(self(), {:gindex_path, provider.id, path, kind})
      {:ok, %{kind => 17}}
    end
  end

  @deps [iptv: IptvStub, gindex: GindexStub]

  test "recognizes only the bounded task protocol" do
    assert SyncTask.supported_type?(:iptv_movies)
    assert SyncTask.supported_type?("gindex_series")
    refute SyncTask.supported_type?("unknown")
    refute SyncTask.supported_type?(123)
  end

  describe "execute/2 IPTV routing" do
    test "routes every supported section through the IPTV facade" do
      cases = [
        {"iptv_categories", :categories, %{categories: 3}},
        {"iptv_live", :live, %{live_channels: 5}},
        {"iptv_movies", :movies, %{movies: 7}},
        {"iptv_series", :series, %{series: 11}}
      ]

      Enum.each(cases, fn {type, section, expected} ->
        assert {:ok, ^type, ^expected} = execute(%{"type" => type, "provider_id" => 7})
        assert_receive {:iptv_section, ^section}
      end)
    end

    test "normalizes a decimal provider id before lookup" do
      assert {:ok, "iptv_movies", %{movies: 7}} =
               execute(%{"type" => "iptv_movies", "provider_id" => "7"})

      assert_receive {:iptv_section, :movies}
    end

    test "discards a task for the wrong provider adapter" do
      assert {:error, "iptv_movies", :not_xtream_provider, :discard} =
               execute(%{"type" => "iptv_movies", "provider_id" => 8})
    end

    test "retries a runtime provider failure" do
      opts = Keyword.put(@deps, :iptv, FailingIptvStub)

      assert {:error, "iptv_movies", {:vod_sync_failed, :timeout}, :retry} =
               execute(%{"type" => "iptv_movies", "provider_id" => 7}, opts)
    end
  end

  describe "execute/2 GIndex routing" do
    test "routes a full sync through the GIndex facade" do
      assert {:ok, "gindex_full_sync", %{movies_count: 13}} =
               execute(%{"type" => "gindex_full_sync", "provider_id" => 7})

      assert_receive {:gindex_provider, 7}
    end

    test "maps path tasks to their bounded kinds" do
      cases = [
        {"gindex_movies", :movies},
        {"gindex_series", :series},
        {"gindex_animes", :animes}
      ]

      Enum.each(cases, fn {type, kind} ->
        path = "/0:/#{kind}/"

        assert {:ok, ^type, %{^kind => 17}} =
                 execute(%{"type" => type, "provider_id" => 7, "path" => path})

        assert_receive {:gindex_path, 7, ^path, ^kind}
      end)
    end
  end

  describe "execute/2 input validation" do
    test "discards malformed JSON without retaining its body in the error" do
      assert {:error, nil, {:invalid_json, %{position: position}}, :discard} =
               SyncTask.execute("{", @deps)

      assert is_integer(position)
    end

    test "requires a JSON object with a bounded string type" do
      assert {:error, nil, {:invalid_task, :expected_object}, :discard} =
               SyncTask.execute("[]", @deps)

      assert {:error, nil, {:invalid_task, :type}, :discard} =
               execute(%{"provider_id" => 7})

      assert {:error, nil, {:invalid_task, :type}, :discard} =
               execute(%{"type" => String.duplicate("x", 101), "provider_id" => 7})
    end

    test "discards unknown task types" do
      assert {:error, "nope", {:unknown_task_type, "nope"}, :discard} =
               execute(%{"type" => "nope", "provider_id" => 7})
    end

    test "requires a positive integer provider id" do
      for provider_id <- [nil, 0, -1, 1.5, "", "7x"] do
        task = %{"type" => "iptv_live"}
        task = if is_nil(provider_id), do: task, else: Map.put(task, "provider_id", provider_id)

        assert {:error, "iptv_live", {:invalid_task, :provider_id}, :discard} = execute(task)
      end
    end

    test "discards tasks whose provider no longer exists" do
      assert {:error, "iptv_live", :provider_not_found, :discard} =
               execute(%{"type" => "iptv_live", "provider_id" => 999})
    end

    test "requires a non-empty path for GIndex path tasks" do
      assert {:error, "gindex_movies", {:invalid_task, :path}, :discard} =
               execute(%{"type" => "gindex_movies", "provider_id" => 7, "path" => "  "})
    end
  end

  defp execute(task, opts \\ @deps) do
    task
    |> Jason.encode!()
    |> SyncTask.execute(opts)
  end
end
