defmodule Streamix.Workers.Gindex.BackfillTmdbWorkerTest do
  use ExUnit.Case, async: true

  alias Streamix.Workers.Gindex.BackfillTmdbWorker

  test "formats structured miss reasons without invoking String.Chars" do
    assert BackfillTmdbWorker.format_miss_reason(:no_results) == "no_results"

    assert BackfillTmdbWorker.format_miss_reason({:http_error, 400}) ==
             "{:http_error, 400}"
  end
end
