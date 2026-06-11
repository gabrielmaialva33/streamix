defmodule Streamix.Subtitles.Source do
  @moduledoc """
  Behaviour for external subtitle providers (OpenSubtitles, SubDL, …).

  A provider resolves a subtitle for an IMDb id + language and returns
  the raw SRT/VTT bytes. The `Streamix.Subtitles` facade owns caching,
  VTT normalization, and graceful degradation, so providers stay thin:
  search, pick the best match, download, return bytes.
  """

  @doc "Stable slug for config + logging."
  @callback slug() :: String.t()

  @doc "True when the provider has the credentials/config it needs."
  @callback enabled?() :: boolean()

  @doc """
  Resolves subtitle bytes for an IMDb id (e.g. `"tt1234567"`) and a
  language tag (e.g. `"pt-BR"`). Returns the raw subtitle body (SRT or
  VTT) on success.
  """
  @callback fetch(imdb_id :: String.t(), lang :: String.t()) ::
              {:ok, binary()} | {:error, term()}
end
