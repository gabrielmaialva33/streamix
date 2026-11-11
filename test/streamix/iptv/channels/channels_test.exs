defmodule Streamix.Iptv.ChannelsTest do
  use Streamix.DataCase, async: true

  import Streamix.IptvFixtures

  alias Streamix.Iptv.{Category, Channels}

  test "providers' 24h category names collapse to one label per kind" do
    for {category, label} <- [
          {"24H | Séries", "Séries"},
          {"24H | Desenhos", "Desenhos"},
          {"24H | Documentarios", "Documentários"},
          {"24HRS I SHOWS", "Shows"},
          {"24H | Shows", "Shows"},
          {"24HRS ✝️ Caminho da Fé", "Fé"},
          {"24 HORAS FILMES", "Filmes"},
          {"24H | Novelas", "Novelas"},
          {"24H", "Outros"}
        ] do
      assert Channels.round_the_clock_label(category) == label, category
    end
  end

  test "lists named channels before placeholder and event channels" do
    provider = global_provider_fixture()

    for name <- ["(01)", "21:30 • Hawks x Lakers", "[F1] Piloto", "Globo SP", "01 - Band", "ESPN"],
        do: channel_fixture(provider, %{name: name})

    names = nil |> Channels.list_visible(limit: 50) |> Enum.map(& &1.name)

    assert Enum.take(names, 3) == ["01 - Band", "ESPN", "Globo SP"]

    assert names |> Enum.drop(3) |> Enum.sort() ==
             Enum.sort(["(01)", "21:30 • Hawks x Lakers", "[F1] Piloto"])
  end

  test "series names lose their part numbers" do
    for {name, key} <- [
          {"Chaves 02", "chaves"},
          {"Dois Homens e Meio (Parte 1)", "dois homens e meio"},
          {"Bob Esponja Part 01", "bob esponja"},
          {"Big Bang: A Teoria 2", "big bang: a teoria"},
          {"3 Palavrinhas", "3 palavrinhas"}
        ] do
      assert Channels.series_key(name) == key, name
    end
  end

  test "24h channels show a series poster, never a placeholder logo shared by many" do
    provider = global_provider_fixture()

    category =
      %Category{}
      |> Category.changeset(%{
        provider_id: provider.id,
        name: "24H | Séries",
        type: "live",
        external_id: Integer.to_string(System.unique_integer([:positive]))
      })
      |> Repo.insert!()

    series_content_fixture(provider, %{
      title: "Chaves",
      cover: "https://img.test/chaves-poster.jpg"
    })

    series_content_fixture(provider, %{
      title: "Chapolin Colorado",
      cover: "https://img.test/chapolin-poster.jpg"
    })

    channels =
      for {name, icon} <- [
            {"Chaves 02", "https://img.test/placeholder.png"},
            {"Doctor Who", "https://img.test/placeholder.png"},
            {"Breaking Bad", "https://img.test/placeholder.png"},
            {"Seinfeld", "https://img.test/seinfeld-logo.png"},
            {"Chapolin 02", nil}
          ] do
        channel = channel_fixture(provider, %{name: name, stream_icon: icon})

        Repo.insert_all("item_categories", [
          %{catalog_item_id: channel.catalog_item_id, category_id: category.id}
        ])

        {name, channel.id}
      end

    assert [%{label: "Séries", channels: listed}] = Channels.list_round_the_clock(nil)
    by_name = Map.new(listed, &{&1.name, &1})

    assert by_name["Chaves 02"].poster == "https://img.test/chaves-poster.jpg"
    assert by_name["Chaves 02"].logo == nil
    assert by_name["Doctor Who"] |> Map.take([:poster, :logo]) == %{poster: nil, logo: nil}
    assert by_name["Seinfeld"].logo == "https://img.test/seinfeld-logo.png"
    # No series is called just "Chapolin": the one starting with it lends its poster.
    assert by_name["Chapolin 02"].poster == "https://img.test/chapolin-poster.jpg"
    assert length(channels) == length(listed)
  end
end
