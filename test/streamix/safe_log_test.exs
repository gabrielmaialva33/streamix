defmodule Streamix.SafeLogTest do
  use ExUnit.Case, async: true

  alias Streamix.SafeLog

  describe "redact_url/2" do
    test "redacts Xtream credentials in paths" do
      url = "https://iptv.example/live/customer@example.com/super-secret/123.ts"

      redacted = SafeLog.redact_url(url)

      assert redacted ==
               "https://iptv.example/live/[REDACTED]/[REDACTED]/123.ts"

      refute redacted =~ "customer@example.com"
      refute redacted =~ "super-secret"
    end

    test "redacts userinfo and sensitive query parameters case-insensitively" do
      url =
        "https://user:pass@example.com/get.php?username=alice&password=secret&API_KEY=token"

      assert SafeLog.redact_url(url) ==
               "https://[REDACTED]@example.com/get.php?username=[REDACTED]&password=[REDACTED]&API_KEY=[REDACTED]"
    end

    test "removes control characters before bounding the value" do
      assert SafeLog.redact_url("https://example.com/a\nb", max_length: 22) ==
               "https://example.com/a…"
    end

    test "does not raise for non-text input" do
      assert SafeLog.redact_url(nil) == "[invalid-url]"
      assert SafeLog.redact_url(<<255>>) == "[invalid-utf8]"
    end
  end

  describe "redact_inspect/2" do
    test "redacts secrets nested inside transport errors without losing the error class" do
      reason = %Req.HTTPError{
        protocol: :http1,
        reason:
          {:invalid_request_target,
           "/2 Fast 2 Furious.mp4?login=firevods&stream_id=3333506&token=top-secret"}
      }

      redacted = SafeLog.redact_inspect(reason)

      assert redacted =~ "Req.HTTPError"
      assert redacted =~ "invalid_request_target"
      assert redacted =~ "stream_id=3333506"
      assert redacted =~ "token=[REDACTED]"
      refute redacted =~ "top-secret"
    end
  end

  describe "scalar/2" do
    test "bounds text and rejects nested client payloads" do
      assert SafeLog.scalar("abcdef", 4) == "abc…"
      assert SafeLog.scalar("one\ntwo", 20) == "one two"
      assert SafeLog.scalar(%{"nested" => "payload"}, 20) == "[unsupported]"
    end

    test "preserves primitive JSON scalars" do
      assert SafeLog.scalar(true) == true
      assert SafeLog.scalar(42) == 42
      assert SafeLog.scalar(nil) == nil
    end
  end
end
