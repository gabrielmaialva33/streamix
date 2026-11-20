defmodule Streamix.Security.UrlValidatorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Streamix.Security.UrlValidator

  describe "validate_url/1" do
    test "allows http and https URLs with public IP literals" do
      assert :ok = UrlValidator.validate_url("http://93.184.216.34/stream.ts")
      assert :ok = UrlValidator.validate_url("https://93.184.216.34/video.mp4")
    end

    test "blocks unsafe schemes and missing hosts" do
      capture_log(fn ->
        assert {:error, :unsafe_url} = UrlValidator.validate_url("file:///etc/passwd")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("javascript:alert(1)")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://example.com:bad/path")
      end)
    end

    test "blocks URLs containing embedded credentials" do
      capture_log(fn ->
        assert {:error, :unsafe_url} =
                 UrlValidator.validate_url("https://user:secret@example.com/image.jpg")
      end)
    end

    test "blocks private and metadata IP literals" do
      capture_log(fn ->
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://127.0.0.1/")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://10.0.0.1/")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://172.16.0.1/")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://192.168.1.1/")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://169.254.169.254/")
      end)
    end

    test "allows a private target only for an explicitly trusted server-side provider" do
      assert :ok =
               UrlValidator.validate_url("http://10.8.0.10/player_api.php",
                 allow_private_network: true
               )
    end

    test "fails closed when a hostname cannot be resolved" do
      capture_log(fn ->
        assert {:error, :unsafe_url} =
                 UrlValidator.validate_url("https://host-that-does-not-exist.invalid/image.jpg")
      end)
    end

    test "blocks carrier-grade NAT and multicast literals" do
      capture_log(fn ->
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://100.64.0.1/image.jpg")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://224.0.0.1/image.jpg")
      end)
    end

    test "an unresolvable host is resolved once then served from the negative cache" do
      parent = self()
      host = "gone-#{System.unique_integer([:positive])}.example.invalid"

      resolver = fn _host, _family, _timeout ->
        send(parent, :resolve)
        {:error, :nxdomain}
      end

      capture_log(fn ->
        assert {:error, :unsafe_url} =
                 UrlValidator.validate_url("https://#{host}/image.jpg", resolver: resolver)

        assert {:error, :unsafe_url} =
                 UrlValidator.validate_url("https://#{host}/image.jpg", resolver: resolver)
      end)

      # Two families resolved on the first call, nothing on the second.
      assert_received :resolve
      assert_received :resolve
      refute_received :resolve
    end

    test "resolution is bounded by the DNS timeout" do
      host = "slow-#{System.unique_integer([:positive])}.example.invalid"

      # Simulates a resolver that hangs past the bounded timeout; the task
      # is killed long before this sleep ends.
      resolver = fn _host, _family, _timeout ->
        :timer.sleep(30_000)
        {:ok, []}
      end

      started_at = System.monotonic_time(:millisecond)

      capture_log(fn ->
        assert {:error, :unsafe_url} =
                 UrlValidator.validate_url("https://#{host}/image.jpg", resolver: resolver)
      end)

      assert System.monotonic_time(:millisecond) - started_at < 15_000
    end
  end
end
