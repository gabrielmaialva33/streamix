defmodule Streamix.Iptv.AdultDetectorTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.AdultDetector

  doctest AdultDetector, import: true

  test "matches adult markers case-insensitively" do
    for category <- ["ADULTOS +18", "Conteúdo XXX", "OnlyFans", "Erótico", "Pornô"] do
      assert AdultDetector.adult_category?(category)
    end
  end

  test "rejects regular and invalid category names" do
    refute AdultDetector.adult_category?("Esportes 18")
    refute AdultDetector.adult_category?("Filmes e Séries")
    refute AdultDetector.adult_category?(nil)
    refute AdultDetector.adult_category?(42)
  end
end
