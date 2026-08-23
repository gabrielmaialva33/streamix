defmodule StreamixWeb.WatchPartyLive.StatusTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.WatchPartyLive.Status

  test "keeps stable playback silent for both roles" do
    refute Status.show?(true, :online, "synced")
    refute Status.show?(false, :online, "synced")
    assert Status.show?(false, :offline, "synced")
  end

  test "formats actionable synchronization states" do
    assert Status.text(false, :offline, "synced", nil) ==
             "Anfitrião desconectado — aguardando retorno"

    assert Status.text(false, :online, "correcting", 275) ==
             "Ajustando sincronização (275 ms)"

    assert Status.text(false, :online, "buffering", nil) == "Aguardando o buffer"
    assert Status.text(true, :online, "synced", nil) == "Você controla a reprodução"
  end

  test "maps failure and recovery states to distinct visual modifiers" do
    assert Status.class(false, :online, "disconnected") =~ "bg-error/90"
    assert Status.class(false, :online, "correcting") =~ "bg-warning/90"
    assert Status.class(false, :online, "synced") =~ "bg-success/90"
    assert Status.class(true, :online, "synced") =~ "bg-brand/90"
  end
end
