defmodule Streamix.AI.TagClassifierTest do
  use ExUnit.Case, async: false

  alias Streamix.AI.TagClassifier

  setup do
    gemini = Application.get_env(:streamix, :gemini)
    req = Req.default_options()
    Application.put_env(:streamix, :gemini, api_key: "test-key")
    Req.default_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      if gemini,
        do: Application.put_env(:streamix, :gemini, gemini),
        else: Application.delete_env(:streamix, :gemini)

      Req.default_options(req)
    end)
  end

  @docs [
    %{
      variant_key: "tmdb:1",
      title: "Pânico",
      year: 1996,
      genres: "Terror, Mistério",
      keywords: ["slasher", "masked killer"],
      directors: ["Wes Craven"],
      cast: [],
      plot: "Um assassino mascarado aterroriza uma cidade."
    },
    %{variant_key: "tmdb:2", title: "Natal em Família", plot: "Uma família se reúne."}
  ]

  test "sends every title with its facts and maps answers back by ref" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(owner, {:request, conn, Jason.decode!(raw)})

      gemini_json(conn, [
        %{"ref" => 2, "subgenres" => ["natal"], "moods" => ["aconchegante"]},
        %{"ref" => 1, "subgenres" => ["slasher"], "pace" => "acelerado"},
        %{"ref" => 9, "subgenres" => ["zumbi"]}
      ])
    end)

    assert {:ok, [{"tmdb:1", first}, {"tmdb:2", second}], usage} = TagClassifier.classify(@docs)
    assert first.subgenres == ["slasher"]
    assert first.pace == "acelerado"
    assert second.subgenres == ["natal"]
    assert usage == %{"promptTokenCount" => 10}

    assert_received {:request, conn, body}
    assert conn.request_path == "/v1beta/models/#{TagClassifier.model()}:generateContent"
    assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == ["test-key"]
    refute conn.query_string =~ "key"

    [%{"parts" => [%{"text" => prompt}]}] = body["contents"]
    assert prompt =~ "[1] Pânico (1996)"
    assert prompt =~ "Palavras-chave TMDB: slasher, masked killer"
    assert prompt =~ "Direção: Wes Craven"
    assert prompt =~ "[2] Natal em Família\nSinopse: Uma família se reúne."

    schema = body["generationConfig"]["responseSchema"]
    assert "slasher" in schema["items"]["properties"]["subgenres"]["items"]["enum"]
    assert schema["items"]["properties"]["pace"]["type"] == "STRING"
  end

  test "a spent daily quota is reported and never retried" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, :requested)

      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{
        "error" => %{
          "code" => 429,
          "details" => [
            %{
              "violations" => [
                %{"quotaId" => "GenerateRequestsPerDayPerProjectPerModel-FreeTier"}
              ]
            }
          ]
        }
      })
    end)

    assert TagClassifier.classify(@docs) == {:error, :quota_exhausted}
    assert_received :requested
    refute_received :requested
  end

  test "a busy model is retried before giving up" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> Plug.Conn.send_resp(conn, 503, ~s({"error":{"code":503}}))
        _ -> gemini_json(conn, [%{"ref" => 1, "moods" => ["tenso"]}])
      end
    end)

    assert {:ok, [{"tmdb:1", %{moods: ["tenso"]}}], _usage} =
             TagClassifier.classify(Enum.take(@docs, 1), max_retries: 1)
  end

  test "an empty batch makes no request" do
    Req.Test.stub(__MODULE__, fn _conn -> flunk("requested") end)
    assert TagClassifier.classify([]) == {:ok, [], %{}}
  end

  defp gemini_json(conn, answers) do
    Req.Test.json(conn, %{
      "candidates" => [%{"content" => %{"parts" => [%{"text" => Jason.encode!(answers)}]}}],
      "usageMetadata" => %{"promptTokenCount" => 10}
    })
  end
end
