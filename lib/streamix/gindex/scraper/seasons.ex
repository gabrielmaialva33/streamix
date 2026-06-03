defmodule Streamix.Gindex.Scraper.Seasons do
  @moduledoc """
  Season-folder detection used by the GIndex scraper.
  """

  @spec season_folder?(%{name: String.t()}) :: boolean()
  def season_folder?(folder) do
    name = folder.name

    Regex.match?(~r/^S\d{1,2}$/i, name) or
      Regex.match?(~r/^Season\s*\d{1,2}$/i, name) or
      Regex.match?(~r/\.S\d{1,2}\./i, name) or
      Regex.match?(~r/S\d{1,2}[^a-zA-Z]/i, name) or
      Regex.match?(~r/^Temporada\s*\d{1,2}\b/iu, name) or
      Regex.match?(~r/^\d{1,2}ª?\s*Temporada\b/iu, name) or
      Regex.match?(~r/^T\d{1,2}\b/i, name) or
      Regex.match?(~r/^(Vol(?:ume|\.)?)\s*\d{1,2}\b/i, name)
  end
end
