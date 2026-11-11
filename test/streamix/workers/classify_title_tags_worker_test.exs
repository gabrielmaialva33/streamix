defmodule Streamix.Workers.ClassifyTitleTagsWorkerTest do
  use Streamix.DataCase, async: false

  import Streamix.IptvFixtures

  alias Streamix.Catalog
  alias Streamix.Iptv.Tags
  alias Streamix.Workers.ClassifyTitleTagsWorker

  setup do
    gemini = Application.get_env(:streamix, :gemini)
    config = Application.get_env(:streamix, ClassifyTitleTagsWorker)
    req = Req.default_options()

    Application.put_env(:streamix, :gemini, api_key: "test-key")

    Application.put_env(:streamix, ClassifyTitleTagsWorker,
      limit: 100,
      batch_size: 2,
      concurrency: 1
    )

    Req.default_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      restore(:gemini, gemini)
      restore(ClassifyTitleTagsWorker, config)
      Req.default_options(req)
    end)

    %{provider: global_provider_fixture()}
  end

  test "classifies every pending title and leaves nothing pending", %{provider: provider} do
    movies =
      for n <- 1..3, do: movie_fixture(provider, %{title: "Filme #{n}", plot: "Sinopse #{n}"})

    series = series_content_fixture(provider, %{title: "Série", plot: "Uma série."})

    Req.Test.stub(__MODULE__, fn conn ->
      answer(conn, fn ref -> %{"ref" => ref, "moods" => ["leve"], "eras" => ["atualidade"]} end)
    end)

    assert :ok = ClassifyTitleTagsWorker.perform(%Oban.Job{args: %{}})

    assert Catalog.pending_tag_count(:movies) == 0
    assert Catalog.pending_tag_count(:series) == 0

    for movie <- movies do
      assert %{moods: ["leve"]} = tags_of("movies", movie)
    end

    assert %{moods: ["leve"]} = tags_of("series", series)

    Req.Test.stub(__MODULE__, fn _conn -> flunk("asked again") end)
    assert :ok = ClassifyTitleTagsWorker.perform(%Oban.Job{args: %{}})
  end

  test "a spent quota stops the run and leaves titles pending", %{provider: provider} do
    movie_fixture(provider, %{title: "Pendente", plot: "x"})

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{
        "error" => %{"details" => [%{"violations" => [%{"quotaId" => "RequestsPerDay"}]}]}
      })
    end)

    assert :ok = ClassifyTitleTagsWorker.perform(%Oban.Job{args: %{}})
    assert Catalog.pending_tag_count(:movies) == 1
  end

  test "a title left out is asked alone, then stored empty", %{provider: provider} do
    kept = movie_fixture(provider, %{title: "Respondido", plot: "x"})
    dropped = movie_fixture(provider, %{title: "Ignorado", plot: "x"})

    # Answers by title, never by position: pending order follows variant
    # keys, which fixtures may base on a random TMDB id.
    Req.Test.stub(__MODULE__, fn conn ->
      {conn, prompt} = prompt(conn)

      case refs_by_title(prompt) do
        %{"Respondido" => ref} ->
          gemini(conn, Jason.encode!([%{"ref" => ref, "moods" => ["tenso"]}]))

        %{"Ignorado" => _ref} ->
          gemini(conn, "not json")
      end
    end)

    assert :ok = ClassifyTitleTagsWorker.perform(%Oban.Job{args: %{}})

    assert %{moods: ["tenso"]} = tags_of("movies", kept)
    assert %{moods: []} = tags_of("movies", dropped)
    assert Catalog.pending_tag_count(:movies) == 0
  end

  test "a limit arg bounds the run", %{provider: provider} do
    for n <- 1..3, do: movie_fixture(provider, %{title: "Limite #{n}", plot: "x"})

    Req.Test.stub(__MODULE__, fn conn ->
      answer(conn, fn ref -> %{"ref" => ref} end)
    end)

    assert :ok = ClassifyTitleTagsWorker.perform(%Oban.Job{args: %{"limit" => 2}})
    assert Catalog.pending_tag_count(:movies) == 1
  end

  test "runs on its own queue, one at a time" do
    changeset = ClassifyTitleTagsWorker.new(%{})
    assert Ecto.Changeset.get_field(changeset, :queue) == "tags"
    assert Ecto.Changeset.get_field(changeset, :unique).period == :infinity
  end

  defp prompt(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    [%{"parts" => [%{"text" => prompt}]}] = Jason.decode!(raw)["contents"]
    {conn, prompt}
  end

  defp refs_by_title(prompt) do
    ~r/^\[(\d+)\] (.+?)(?: \(\d{4}\))?$/m
    |> Regex.scan(prompt)
    |> Map.new(fn [_, ref, title] -> {title, String.to_integer(ref)} end)
  end

  defp answer(conn, fun) do
    {conn, prompt} = prompt(conn)
    answer(conn, prompt, fun)
  end

  # Answers one object per "[n]" ref in the prompt; nil drops that title.
  defp answer(conn, prompt, fun) do
    answers =
      ~r/^\[(\d+)\]/m
      |> Regex.scan(prompt)
      |> Enum.map(fn [_, ref] -> fun.(String.to_integer(ref)) end)
      |> Enum.reject(&is_nil/1)

    gemini(conn, Jason.encode!(answers))
  end

  defp gemini(conn, text) do
    Req.Test.json(conn, %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text}]}}]})
  end

  defp tags_of(kind, content) do
    key =
      Repo.one!(from(c in kind, where: c.id == ^content.id, select: c.variant_key))

    Map.get(Tags.for_variants(kind, [key]), key)
  end

  defp restore(key, nil), do: Application.delete_env(:streamix, key)
  defp restore(key, value), do: Application.put_env(:streamix, key, value)
end
