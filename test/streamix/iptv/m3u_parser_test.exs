defmodule Streamix.Iptv.M3uParserTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.M3uParser, as: Parser

  @sample """
  #EXTM3U
  #EXTINF:-1 tvg-id="globo.sp" tvg-name="Globo SP" tvg-logo="https://logo/globo.png" group-title="Live - Abertos",Globo SP HD
  http://server.example.com/live/user1/pass1/1001.ts
  #EXTINF:-1 tvg-id="" tvg-name="Filme do Marlon (2024)" tvg-logo="https://poster/marlon.jpg" group-title="VOD - Filmes Nacionais",Filme do Marlon (2024)
  http://server.example.com/movie/user1/pass1/2002.mp4
  #EXTINF:-1 tvg-id="" tvg-name="Stranger Things S03 E01" tvg-logo="https://poster/st.jpg" group-title="Series - Netflix",Stranger Things S03 E01
  http://server.example.com/series/user1/pass1/3003.mkv
  """

  test "parses a mixed live + movie + episode body" do
    [live, movie, episode] = Parser.parse(@sample)

    assert {:live, live_attrs} = live
    assert live_attrs.stream_id == 1001
    assert live_attrs.tvg_id == "globo.sp"
    assert live_attrs.name == "Globo SP HD"
    assert live_attrs.group_title == "Live - Abertos"
    assert live_attrs.extension == "ts"

    assert {:movie, movie_attrs} = movie
    assert movie_attrs.stream_id == 2002
    assert movie_attrs.extension == "mp4"
    assert movie_attrs.name == "Filme do Marlon (2024)"

    assert {:episode, ep_attrs} = episode
    assert ep_attrs.stream_id == 3003
    assert ep_attrs.extension == "mkv"
    assert ep_attrs.group_title == "Series - Netflix"
  end

  test "ignores #EXTM3U header, comments and empty lines" do
    body = """
    #EXTM3U

    # a stray comment
    #EXTINF:-1 tvg-id="x" tvg-name="X" tvg-logo="" group-title="g",Name
    http://h/live/u/p/9.ts
    """

    assert [{:live, %{stream_id: 9}}] = Parser.parse(body)
  end

  test "drops entries whose URL doesn't match the Xtream layout" do
    body = """
    #EXTINF:-1 tvg-id="x" tvg-name="X" tvg-logo="" group-title="g",Name
    http://otherhost/somewhere/else
    #EXTINF:-1 tvg-id="y" tvg-name="Y" tvg-logo="" group-title="g",Y
    http://h/live/u/p/55.ts
    """

    assert [{:live, %{stream_id: 55}}] = Parser.parse(body)
  end

  test "parse_stream/1 works on chunked enumerable" do
    chunks = [
      "#EXTM3U\n#EXTINF:-1 tvg-id=\"a\" tvg-name=\"A\" tvg-logo=\"\" group-title=\"g\",A\nhttp://h/li",
      "ve/u/p/1.ts\n#EXTINF:-1 tvg-id=\"\" tvg-name=\"M\" tvg-logo=\"\" group-title=\"g\",M\nhttp://h/movie/u/p/2.mp4\n"
    ]

    entries = chunks |> Parser.parse_stream() |> Enum.to_list()
    assert [{:live, %{stream_id: 1}}, {:movie, %{stream_id: 2}}] = entries
  end

  test "preserves commas inside the display name (group-title before final comma)" do
    body = """
    #EXTINF:-1 tvg-id="" tvg-name="" tvg-logo="" group-title="g",Name, with, commas
    http://h/movie/u/p/7.mp4
    """

    assert [{:movie, attrs}] = Parser.parse(body)
    assert attrs.name == "Name, with, commas"
  end
end
