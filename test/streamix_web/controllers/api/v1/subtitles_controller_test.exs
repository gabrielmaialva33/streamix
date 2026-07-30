defmodule StreamixWeb.Api.V1.SubtitlesControllerTest do
  use StreamixWeb.ConnCase, async: false

  alias Streamix.Cache

  defmodule StubHit do
    @behaviour Streamix.Subtitles.Source

    def slug, do: "controller-hit"
    def enabled?, do: true
    def fetch(_imdb_id, _lang), do: {:ok, "1\n00:00:01,000 --> 00:00:02,000\nOlá\n"}
  end

  defmodule StubDisabled do
    @behaviour Streamix.Subtitles.Source

    def slug, do: "controller-disabled"
    def enabled?, do: false
    def fetch(_imdb_id, _lang), do: {:error, :unexpected_call}
  end

  setup do
    previous_providers = Application.get_env(:streamix, :subtitle_providers)
    cache_key = "subtitles:vtt:controller-hit:tt0111161:pt-br"
    Cache.delete(cache_key)

    on_exit(fn ->
      if previous_providers do
        Application.put_env(:streamix, :subtitle_providers, previous_providers)
      else
        Application.delete_env(:streamix, :subtitle_providers)
      end

      Cache.delete(cache_key)
    end)

    :ok
  end

  test "returns a normalized WebVTT subtitle", %{conn: conn} do
    Application.put_env(:streamix, :subtitle_providers, [StubHit])

    conn =
      conn
      |> put_req_header("accept", "text/vtt")
      |> get("/api/subtitles/tt0111161?lang=pt-BR")

    assert response(conn, 200) =~ "WEBVTT"
    assert response(conn, 200) =~ "00:00:01.000 --> 00:00:02.000"
    assert get_resp_header(conn, "content-type") == ["text/vtt; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=86400"]
  end

  test "applies a bounded playback offset without changing the cached source", %{conn: conn} do
    Application.put_env(:streamix, :subtitle_providers, [StubHit])

    shifted =
      conn
      |> get("/api/subtitles/tt0111161?lang=pt-BR&offset_ms=750")
      |> response(200)

    assert shifted =~ "00:00:01.750 --> 00:00:02.750"

    original =
      build_conn()
      |> get("/api/subtitles/tt0111161?lang=pt-BR")
      |> response(200)

    assert original =~ "00:00:01.000 --> 00:00:02.000"
  end

  test "returns 204 when subtitle providers are disabled", %{conn: conn} do
    Application.put_env(:streamix, :subtitle_providers, [StubDisabled])

    conn = get(conn, "/api/subtitles/tt0111161")

    assert response(conn, 204) == ""
  end

  test "rejects an invalid IMDb id", %{conn: conn} do
    response =
      conn
      |> get("/api/subtitles/not-an-imdb-id")
      |> json_response(400)

    assert response == %{
             "error" => %{
               "code" => "invalid_imdb_id",
               "message" => "Invalid IMDb id"
             }
           }
  end
end
