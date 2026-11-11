defmodule Streamix.Iptv.ChannelsTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.Channels

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
end
