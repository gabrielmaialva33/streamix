defmodule Streamix.Subtitles do
  @moduledoc """
  Public API for external subtitles.

  Torrent (and other) content is frequently audio-only with no embedded
  captions. This context resolves a subtitle for an IMDb id + language
  from a chain of pluggable providers (`Streamix.Subtitles.Source`),
  normalizes it to WebVTT, and caches the result so a given imdb_id+lang
  hits the upstream at most once per cache window -- the free tiers have
  tight daily download quotas.

  Multiple providers are tried in order (OpenSubtitles, SubDL, ...); the
  first enabled one that returns a subtitle wins. Returns `:disabled`
  when no provider is configured and `:not_found` when none of them has
  anything, so callers degrade gracefully (the player simply offers no
  external subtitle) instead of erroring.
  """

  require Logger

  alias Streamix.Cache
  alias Streamix.Subtitles.Vtt

  # 30 days -- subtitles for a given release are effectively immutable.
  @cache_ttl_seconds 60 * 60 * 24 * 30

  @default_providers [
    Streamix.Subtitles.OpenSubtitles,
    Streamix.Subtitles.SubDL
  ]

  @doc """
  Returns WebVTT bytes for an IMDb id + language.

      {:ok, vtt} | :not_found | :disabled
  """
  @spec get_vtt(String.t(), String.t()) :: {:ok, binary()} | :not_found | :disabled
  def get_vtt(imdb_id, lang \\ "pt-BR")

  def get_vtt(imdb_id, lang) when is_binary(imdb_id) and imdb_id != "" do
    enabled = enabled_providers()

    cond do
      enabled == [] -> :disabled
      cached = cache_lookup(enabled, imdb_id, lang) -> {:ok, cached}
      true -> fetch_from_chain(enabled, imdb_id, lang)
    end
  end

  def get_vtt(_imdb_id, _lang), do: :not_found

  @doc "True when at least one subtitle provider is configured."
  @spec available?() :: boolean()
  def available?, do: enabled_providers() != []

  @doc "Shifts every WebVTT cue by the requested offset in milliseconds."
  @spec shift_vtt(binary(), integer()) :: binary()
  defdelegate shift_vtt(vtt, offset_ms), to: Vtt, as: :shift

  # A cached entry from any enabled provider is good -- they all yield the
  # same normalized VTT for the title.
  defp cache_lookup(providers, imdb_id, lang) do
    Enum.find_value(providers, fn p -> Cache.get(cache_key(p, imdb_id, lang)) end)
  end

  defp fetch_from_chain([], _imdb_id, _lang), do: :not_found

  defp fetch_from_chain([provider | rest], imdb_id, lang) do
    case provider.fetch(imdb_id, lang) do
      {:ok, raw} ->
        vtt = Vtt.from_srt(raw)
        # Cache only hits -- a miss/error stays uncached so it retries once
        # the upstream recovers or the title gets a subtitle.
        Cache.set(cache_key(provider, imdb_id, lang), vtt, @cache_ttl_seconds)
        {:ok, vtt}

      {:error, reason} ->
        Logger.info(
          "[Subtitles] #{provider.slug()} miss for #{imdb_id} (#{lang}): #{inspect(reason)}"
        )

        fetch_from_chain(rest, imdb_id, lang)
    end
  end

  defp cache_key(provider, imdb_id, lang) do
    "subtitles:vtt:#{provider.slug()}:#{imdb_id}:#{String.downcase(lang)}"
  end

  defp enabled_providers do
    Application.get_env(:streamix, :subtitle_providers, @default_providers)
    |> Enum.filter(& &1.enabled?())
  end
end
