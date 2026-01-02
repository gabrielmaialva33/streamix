defmodule Streamix.Iptv.AdultDetector do
  @moduledoc """
  Detects adult categories based on keyword matching.
  Used during sync to automatically mark adult categories.
  """

  @adult_keywords ~w(
    adult adulto adultos
    xxx
    18+ +18
    porn porno pornograph
    erotic erotico erotica
    onlyfans
  )

  @doc """
  Returns true if the category name matches adult content patterns.

  ## Examples

      iex> AdultDetector.adult_category?("Adultos +18")
      true

      iex> AdultDetector.adult_category?("Sports")
      false
  """
  def adult_category?(name) when is_binary(name) do
    normalized = String.downcase(name)
    Enum.any?(@adult_keywords, &String.contains?(normalized, &1))
  end

  def adult_category?(_), do: false
end
