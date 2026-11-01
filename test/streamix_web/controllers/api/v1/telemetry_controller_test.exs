defmodule StreamixWeb.Api.V1.TelemetryControllerTest do
  use StreamixWeb.ConnCase, async: true

  import Ecto.Query
  import Streamix.AccountsFixtures

  alias Streamix.Repo

  setup do
    original_api_keys = Application.get_env(:streamix, :api_keys, [])
    api_key = "telemetry-test-key"

    Application.put_env(:streamix, :api_keys, [api_key])

    on_exit(fn ->
      Application.put_env(:streamix, :api_keys, original_api_keys)
    end)

    user = user_fixture()
    token = api_token_fixture(user)

    conn =
      build_conn()
      |> put_req_header("x-api-key", api_key)
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn}
  end

  test "accepts the canonical metrics batch", %{conn: conn} do
    batch_id = Ecto.UUID.generate()

    first =
      post(conn, ~p"/api/v1/telemetry/playback", %{
        "batch_id" => batch_id,
        "metrics" => [
          %{
            "stream_type" => "movie",
            "engine" => "native",
            "time_to_first_frame_ms" => 840,
            "buffer_count" => 1,
            "error_count" => 0,
            "url" => "https://upstream.invalid/secret-token"
          }
        ]
      })

    assert %{"accepted" => 1, "batch_id" => ^batch_id} = json_response(first, 202)

    second =
      post(conn, ~p"/api/v1/telemetry/playback", %{
        "batch_id" => batch_id,
        "metrics" => [%{"stream_type" => "movie", "engine" => "native"}]
      })

    assert %{"accepted" => 0, "batch_id" => ^batch_id} = json_response(second, 202)

    event =
      from(event in "qoe_events",
        select: %{
          engine: event.engine,
          ttff_ms: event.ttff_ms,
          batch_id: event.batch_id,
          user_id: event.user_id
        }
      )
      |> Repo.one!()

    assert event.engine == "native"
    assert event.ttff_ms == 840
    assert event.batch_id == batch_id
    # A playback sample says when and what kind of content was played, so it
    # must not say by whom (docs/privacy.md). The column itself stays for one
    # release so the previous image can still write it after a rollback.
    assert event.user_id == nil

    columns =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'qoe_events'"
      ).rows

    refute ["url"] in columns
  end

  test "accepts single event payloads from lightweight clients", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/telemetry/playback", %{
        "event" => "player_error",
        "engine" => "avplayer",
        "content_type" => "movie"
      })

    assert %{"accepted" => 1, "batch_id" => batch_id} = json_response(conn, 202)
    assert {:ok, _uuid} = Ecto.UUID.cast(batch_id)
  end

  test "rejects empty telemetry payloads", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/telemetry/playback", %{})

    assert %{"error" => %{"code" => "invalid_body"}} = json_response(conn, 400)
  end
end
