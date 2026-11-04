defmodule StreamixWeb.ReturnPath do
  @moduledoc """
  The one place that decides whether a `return_to` value may be followed, and
  that appends one to a link.

  A `return_to` comes from the query string, so anyone can write it. Only a
  path on this site is accepted. Browsers read `//host` and `/\\host` as a
  different host, and they drop whitespace and control characters before
  parsing, so any of those turns the value into an open redirect.
  """

  @unsafe ~r/[\s\x00-\x1f\x7f\\]/u

  @doc """
  Returns `path` when it is a path on this site, otherwise `nil`.

      iex> StreamixWeb.ReturnPath.safe("/browse/movies?page=2")
      "/browse/movies?page=2"

      iex> StreamixWeb.ReturnPath.safe("/\\\\evil.example")
      nil
  """
  @spec safe(term()) :: String.t() | nil
  def safe("/" <> rest = path) do
    if String.starts_with?(rest, "/") or path =~ @unsafe, do: nil, else: path
  end

  def safe(_value), do: nil

  @doc """
  Appends `return_to` to `path` as a query parameter, keeping any query that
  `path` already has. An unsafe or missing `return_to` leaves `path` unchanged.
  """
  @spec append(String.t(), term()) :: String.t()
  def append(path, return_to) when is_binary(path) do
    case safe(return_to) do
      nil ->
        path

      return_to ->
        separator = if String.contains?(path, "?"), do: "&", else: "?"
        path <> separator <> URI.encode_query(%{"return_to" => return_to})
    end
  end
end
