defmodule StreamixWeb.PlaywrightMediaFixture do
  @moduledoc """
  Generates short deterministic transport streams for browser-level player tests.

  Fixtures live only for the owning test module and are served by `MediaPlug`,
  including byte-range support for AVPlayer's demuxer.
  """

  @duration_seconds 20

  @spec generate!(Path.t(), :h264) :: Path.t()
  def generate!(directory, :h264) do
    ffmpeg =
      System.find_executable("ffmpeg") ||
        raise "ffmpeg is required for deterministic Playwright media fixtures"

    File.mkdir_p!(directory)
    path = Path.join(directory, "h264.ts")

    args =
      [
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=320x180:rate=25",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=880:sample_rate=48000",
        "-t",
        Integer.to_string(@duration_seconds)
      ] ++ video_args() ++ audio_args() ++ ["-f", "mpegts", "-y", path]

    case System.cmd(ffmpeg, args,
           env: cleared_environment(),
           stderr_to_stdout: true
         ) do
      {_output, 0} -> path
      {output, status} -> raise "ffmpeg fixture generation failed (#{status}): #{output}"
    end
  end

  @spec server_config(Path.t(), pid() | nil) :: map()
  def server_config(path, owner \\ nil) do
    ffmpeg =
      System.find_executable("ffmpeg") ||
        raise "ffmpeg is required for deterministic Playwright media fixtures"

    %{ffmpeg: ffmpeg, owner: owner, path: path, size: File.stat!(path).size}
  end

  defp video_args do
    [
      "-c:v",
      "libx264",
      "-preset",
      "ultrafast",
      "-tune",
      "zerolatency",
      "-pix_fmt",
      "yuv420p",
      "-g",
      "25",
      "-keyint_min",
      "25",
      "-sc_threshold",
      "0"
    ]
  end

  defp audio_args, do: ["-c:a", "aac", "-b:a", "96k"]

  defp cleared_environment do
    System.get_env()
    |> Map.new(fn {name, _value} -> {name, nil} end)
  end

  defmodule MediaPlug do
    @moduledoc false

    import Plug.Conn

    def init([]), do: %{runtime: true}

    def init(opts) do
      path = Keyword.fetch!(opts, :path)
      StreamixWeb.PlaywrightMediaFixture.server_config(path, Keyword.get(opts, :owner))
    end

    def call(conn, %{runtime: true}) do
      state = Application.fetch_env!(:streamix, :playwright_media_fixture)
      call(conn, state)
    end

    def call(%{method: "OPTIONS"} = conn, state) do
      notify_request(conn, state)

      conn
      |> put_common_headers()
      |> put_resp_header("access-control-allow-methods", "GET, HEAD, OPTIONS")
      |> put_resp_header("access-control-allow-headers", "Range")
      |> send_resp(204, "")
    end

    def call(%{method: "HEAD"} = conn, state) do
      notify_request(conn, state)

      conn
      |> put_common_headers()
      |> put_resp_header("content-length", Integer.to_string(state.size))
      |> send_resp(200, "")
    end

    def call(%{method: "GET"} = conn, state) do
      notify_request(conn, state)
      conn = put_common_headers(conn)

      case requested_range(conn, state.size) do
        {:ok, offset, length} ->
          conn
          |> put_resp_header(
            "content-range",
            "bytes #{offset}-#{offset + length - 1}/#{state.size}"
          )
          |> send_file(206, state.path, offset, length)

        :all ->
          stream_live(conn, state)

        :invalid ->
          conn
          |> put_resp_header("content-range", "bytes */#{state.size}")
          |> send_resp(416, "")
      end
    end

    def call(conn, _state), do: send_resp(conn, 404, "not found")

    defp notify_request(conn, %{owner: owner}) when is_pid(owner) do
      send(owner, {:playwright_media_request, conn.method, get_req_header(conn, "range")})
    end

    defp notify_request(_conn, _state), do: :ok

    defp put_common_headers(conn) do
      conn
      |> put_resp_content_type("video/mp2t")
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header(
        "access-control-expose-headers",
        "Accept-Ranges, Content-Length, Content-Range"
      )
      |> put_resp_header("cache-control", "no-store")
    end

    defp stream_live(conn, state) do
      port =
        Port.open(
          {:spawn_executable, state.ffmpeg},
          [
            :binary,
            :exit_status,
            args:
              Enum.map(
                [
                  "-nostdin",
                  "-hide_banner",
                  "-loglevel",
                  "quiet",
                  "-re",
                  "-stream_loop",
                  "-1",
                  "-i",
                  state.path,
                  "-c",
                  "copy",
                  "-f",
                  "mpegts",
                  "pipe:1"
                ],
                &String.to_charlist/1
              )
          ]
        )

      conn
      |> send_chunked(200)
      |> relay_port(port)
    end

    defp relay_port(conn, port) do
      receive do
        {^port, {:data, data}} ->
          case chunk(conn, data) do
            {:ok, conn} ->
              relay_port(conn, port)

            {:error, _reason} ->
              close_port(port)
              conn
          end

        {^port, {:exit_status, _status}} ->
          conn
      end
    end

    defp close_port(port) do
      if Port.info(port), do: Port.close(port)
      true
    rescue
      ArgumentError -> true
    end

    defp requested_range(conn, size) do
      case get_req_header(conn, "range") do
        [] -> :all
        [range] -> parse_range(range, size)
        _ -> :invalid
      end
    end

    defp parse_range("bytes=" <> range, size) do
      case String.split(range, "-", parts: 2) do
        ["", suffix] -> suffix_range(suffix, size)
        [first, last] -> bounded_range(first, last, size)
        _ -> :invalid
      end
    end

    defp parse_range(_, _size), do: :invalid

    defp suffix_range(value, size) do
      case Integer.parse(value) do
        {length, ""} when length > 0 ->
          length = min(length, size)
          {:ok, size - length, length}

        _ ->
          :invalid
      end
    end

    defp bounded_range(first, last, size) do
      with {offset, ""} when offset >= 0 and offset < size <- Integer.parse(first),
           {:ok, requested_last} <- parse_last_byte(last, size),
           true <- requested_last >= offset do
        final_byte = min(requested_last, size - 1)
        {:ok, offset, final_byte - offset + 1}
      else
        _ -> :invalid
      end
    end

    defp parse_last_byte("", size), do: {:ok, size - 1}

    defp parse_last_byte(value, _size) do
      case Integer.parse(value) do
        {last, ""} when last >= 0 -> {:ok, last}
        _ -> :invalid
      end
    end
  end
end
