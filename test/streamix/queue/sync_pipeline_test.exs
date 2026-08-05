defmodule Streamix.Queue.SyncPipelineTest do
  use ExUnit.Case, async: true

  alias Broadway.{CallerAcknowledger, Message}
  alias Streamix.Queue.SyncPipeline

  test "dead-letters malformed JSON without retrying it" do
    {message, ref} = message("{")

    assert %Message{
             status: {:failed, {:invalid_json, %{position: position}}}
           } = SyncPipeline.handle_message(:default, message, %{})

    assert is_integer(position)
    assert_receive {:configure, ^ref, [on_failure: :reject]}
  end

  test "dead-letters an unknown task type with a structured reason" do
    payload = Jason.encode!(%{"type" => "unknown", "provider_id" => 7})
    {message, ref} = message(payload)

    assert %Message{
             status: {:failed, {:unknown_task_type, "unknown"}}
           } = SyncPipeline.handle_message(:default, message, %{})

    assert_receive {:configure, ^ref, [on_failure: :reject]}
  end

  test "returns every failed message from the failure callback" do
    {message, _ref} = message("invalid")
    failed = Message.failed(message, :forced_failure)

    assert SyncPipeline.handle_failed([failed], %{}) == [failed]
  end

  defp message(data) do
    ref = make_ref()

    message = %Message{
      data: data,
      acknowledger: CallerAcknowledger.init({self(), ref}, :ignored)
    }

    {message, ref}
  end
end
