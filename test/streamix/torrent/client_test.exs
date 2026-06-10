defmodule Streamix.Torrent.ClientTest do
  use ExUnit.Case, async: false

  alias Streamix.Torrent.Client

  setup do
    previous = Application.get_env(:streamix, :torrent_provider)

    on_exit(fn ->
      if previous do
        Application.put_env(:streamix, :torrent_provider, previous)
      else
        Application.delete_env(:streamix, :torrent_provider)
      end
    end)

    :ok
  end

  describe "auth_headers/0" do
    test "sends X-Internal-Auth when a secret is configured" do
      Application.put_env(:streamix, :torrent_provider,
        enabled: true,
        rqbit_url: "http://rqbit:3030",
        rqbit_auth_secret: "s3cr3t"
      )

      assert Client.auth_headers() == [{"x-internal-auth", "s3cr3t"}]
    end

    test "omits the header when no secret is set" do
      Application.put_env(:streamix, :torrent_provider,
        enabled: true,
        rqbit_url: "http://rqbit:3030"
      )

      assert Client.auth_headers() == []
    end

    test "treats an empty secret as absent" do
      Application.put_env(:streamix, :torrent_provider,
        enabled: true,
        rqbit_url: "http://rqbit:3030",
        rqbit_auth_secret: ""
      )

      assert Client.auth_headers() == []
    end
  end
end
