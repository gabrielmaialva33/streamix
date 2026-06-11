defmodule Streamix.SubtitlesTest do
  use ExUnit.Case, async: false

  alias Streamix.Cache
  alias Streamix.Subtitles

  defmodule StubHit do
    @behaviour Streamix.Subtitles.Source
    def slug, do: "stubhit"
    def enabled?, do: true
    def fetch(_imdb, _lang), do: {:ok, "1\n00:00:01,000 --> 00:00:02,000\noi\n"}
  end

  defmodule StubMiss do
    @behaviour Streamix.Subtitles.Source
    def slug, do: "stubmiss"
    def enabled?, do: true
    def fetch(_imdb, _lang), do: {:error, :not_found}
  end

  defmodule StubDisabled do
    @behaviour Streamix.Subtitles.Source
    def slug, do: "stubdisabled"
    def enabled?, do: false
    def fetch(_imdb, _lang), do: {:ok, "should not be called"}
  end

  setup do
    prev = Application.get_env(:streamix, :subtitle_providers)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:streamix, :subtitle_providers, prev),
        else: Application.delete_env(:streamix, :subtitle_providers)

      Cache.delete("subtitles:vtt:stubhit:tt0111161:pt-br")
      Cache.delete("subtitles:vtt:stubmiss:tt0111161:pt-br")
    end)

    :ok
  end

  test "returns :disabled when no provider is enabled" do
    Application.put_env(:streamix, :subtitle_providers, [StubDisabled])
    assert Subtitles.get_vtt("tt0111161", "pt-BR") == :disabled
  end

  test "returns normalized VTT from the first enabled provider with a hit" do
    Application.put_env(:streamix, :subtitle_providers, [StubMiss, StubHit])
    assert {:ok, vtt} = Subtitles.get_vtt("tt0111161", "pt-BR")
    assert String.starts_with?(vtt, "WEBVTT")
    assert vtt =~ "00:00:01.000 --> 00:00:02.000"
  end

  test "returns :not_found when all enabled providers miss" do
    Application.put_env(:streamix, :subtitle_providers, [StubMiss])
    assert Subtitles.get_vtt("tt0111161", "pt-BR") == :not_found
  end

  test "rejects blank imdb id" do
    Application.put_env(:streamix, :subtitle_providers, [StubHit])
    assert Subtitles.get_vtt("", "pt-BR") == :not_found
  end
end
