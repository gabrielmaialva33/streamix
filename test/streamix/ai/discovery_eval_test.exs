defmodule Streamix.AI.DiscoveryEvalTest do
  use Streamix.DataCase, async: true

  import Streamix.IptvFixtures

  alias Streamix.AI.DiscoveryEval

  @doc_80s_slasher %{
    genres: "Terror, Mistério",
    year: 1984,
    directors: ["Wes Craven"],
    cast: ["Heather Langenkamp"],
    keywords: ["slasher", "Dream"],
    tags: %{subgenres: ["slasher"], eras: ["anos-1980"]}
  }

  test "a result is relevant when every group has a condition that holds" do
    assert DiscoveryEval.relevant?(@doc_80s_slasher, [
             [{:genre, "Terror"}],
             [{:year, 1980, 1989}, {:tag, :eras, "anos-1990"}]
           ])

    assert DiscoveryEval.relevant?(@doc_80s_slasher, [[{:director, "wes craven"}]])
    assert DiscoveryEval.relevant?(@doc_80s_slasher, [[{:keyword, "dream"}]])
    assert DiscoveryEval.relevant?(@doc_80s_slasher, [[{:tag, :subgenres, "slasher"}]])

    refute DiscoveryEval.relevant?(@doc_80s_slasher, [[{:genre, "Terror"}], [{:year, 1990, 1999}]])

    refute DiscoveryEval.relevant?(%{@doc_80s_slasher | tags: nil}, [
             [{:tag, :subgenres, "slasher"}]
           ])
  end

  test "precision counts missing results as misses" do
    provider = global_provider_fixture()
    hit = movie_fixture(provider, %{title: "Acerto", year: 1985})
    miss = movie_fixture(provider, %{title: "Erro", year: 2001})

    score = DiscoveryEval.score("q", [[{:year, 1980, 1989}]], [hit.id, miss.id])
    assert score.relevant == 1
    assert score.returned == 2
    assert score.precision == 0.1
    assert score.misses == ["Erro"]
  end

  test "every query has well-formed checks" do
    for {query, groups} <- DiscoveryEval.queries() do
      assert is_binary(query) and groups != []

      for group <- groups, condition <- group do
        assert elem(condition, 0) in [:genre, :year, :director, :cast, :keyword, :tag], query
      end
    end
  end
end
