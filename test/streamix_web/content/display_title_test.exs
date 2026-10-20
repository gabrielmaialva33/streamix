defmodule StreamixWeb.Content.DisplayTitleTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.Content.DisplayTitle

  # Names captured from production on 2026-10-20.
  test "drops release noise from the end and from brackets" do
    for {raw, clean} <- [
          {"Armadilha [LEG]", "Armadilha"},
          {"1978 [L]", "1978"},
          {"22 de Julho 4K [Hybrid]", "22 de Julho"},
          {"Meu Nome é Eneas 4K", "Meu Nome é Eneas"},
          {"Amor² 2021 1080p WEB-DL x264 Dual audio", "Amor²"},
          {"Efeitos Colaterais [LEG] (2025) (2025)", "Efeitos Colaterais"},
          {"Coyote vs. ACME (2026)", "Coyote vs. ACME"},
          {"[Reel] A Noiva do Deus das Lâminas", "A Noiva do Deus das Lâminas"},
          {"Batman - O Cavaleiro das Trevas - Dublado", "Batman - O Cavaleiro das Trevas"},
          {"Dawsons.Creek.S01E01.Pilot.1080p.WEB-DL", "Dawsons Creek S01E01 Pilot"},
          {"Acusada 2019 Dublado 720p + 1080p", "Acusada"},
          {"A Invocação 2012 [720p] [WEB-DL] [DUAL]", "A Invocação"},
          {"Jornada nas Estrelas IX - Insurreição (1998) Dublado 1080p",
           "Jornada nas Estrelas IX - Insurreição"},
          {"Sequestro 1971 [L]", "Sequestro 1971"},
          {"Blade Runner 2049 2017 [WEB-DL] [1080p] [DUAL]", "Blade Runner 2049"},
          {"2067 (2020) 1080p BluRay DD+5 1 x264-DUAL", "2067"},
          {"Blade Runner 2049 (2017) 1080p", "Blade Runner 2049"}
        ] do
      assert DisplayTitle.clean(raw) == clean, inspect(raw)
    end
  end

  test "keeps real titles that look like noise" do
    for title <- [
          "Blade Runner 2049",
          "1917",
          "2012",
          "Hybrid",
          "Nacional",
          "Os 4 Fantásticos",
          "Missão: Impossível - Acerto de Contas"
        ] do
      assert DisplayTitle.clean(title) == title, inspect(title)
    end

    # A bare year at the end only goes together with release noise.
    assert DisplayTitle.clean("Blade Runner 2049 4K") == "Blade Runner"
    assert DisplayTitle.clean("1917 4K") == "1917"
  end

  test "reads title or name from an item and never returns nothing" do
    assert DisplayTitle.title(%{title: nil, name: "Armadilha [LEG]"}) == "Armadilha"
    assert DisplayTitle.title(%{title: "Piloto", name: "x"}) == "Piloto"
    assert DisplayTitle.title(%{name: nil}) == ""
    assert DisplayTitle.clean("[LEG]") == "[LEG]"
    assert DisplayTitle.clean(nil) == ""
  end

  test "episode titles lose the series name and code a provider prepends" do
    assert DisplayTitle.episode("Dawson's Creek - S01E01 - Piloto") == "Piloto"
    assert DisplayTitle.episode("S02E10 - O Retorno") == "O Retorno"
    assert DisplayTitle.episode("Piloto") == "Piloto"
    assert DisplayTitle.episode("Dawson's Creek - S01E01 - ") == "Dawson's Creek - S01E01"
  end

  test "channel names lose the provider's number and emoji" do
    assert DisplayTitle.channel("(01) ⏰ 13:45 • Fenerbahçe x Slavia Praha") ==
             "13:45 • Fenerbahçe x Slavia Praha"

    assert DisplayTitle.channel("RECORD SIC TV RONDÔNIA FHD") == "RECORD SIC TV RONDÔNIA FHD"
    assert DisplayTitle.channel("(16)") == "(16)"
  end
end
