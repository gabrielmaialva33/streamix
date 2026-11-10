defmodule Streamix.GuideTest do
  use ExUnit.Case, async: true

  alias Streamix.Guide

  @now ~U[2026-11-05 12:00:00Z]

  test "a guide never synchronized is due" do
    assert Guide.epg_due?(%{epg_synced_at: nil}, @now)
  end

  test "a guide is due once its interval has passed" do
    refute Guide.epg_due?(%{epg_synced_at: ~U[2026-11-05 07:00:00Z]}, @now)
    assert Guide.epg_due?(%{epg_synced_at: ~U[2026-11-05 06:00:00Z]}, @now)

    refute Guide.epg_due?(
             %{epg_synced_at: ~U[2026-11-05 06:00:00Z], epg_sync_interval_hours: 12},
             @now
           )
  end
end
