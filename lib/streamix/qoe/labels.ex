defmodule Streamix.Qoe.Labels do
  @moduledoc false

  @end_reasons ~w(completed navigation first_frame_then_user_left user_retry startup_deadline recovery_deadline retry_budget fatal_media_error network_error unknown)
  @engine_reasons ~w(capability provider_memory format_memory fallback_audio fallback_codec failover user_choice unknown)
  @error_codes ~w(media_aborted media_network media_decode media_unsupported media_unknown play_rejected)

  def end_reason(value) when value in @end_reasons, do: value
  def end_reason(_), do: nil
  def engine_reason(value) when value in @engine_reasons, do: value
  def engine_reason(_), do: nil
  def error_code(value) when value in @error_codes, do: value
  def error_code(_), do: nil

  def client_revision(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-fA-F]{7,40}\z/, value), do: String.downcase(value)
  end

  def client_revision(_), do: nil
end
