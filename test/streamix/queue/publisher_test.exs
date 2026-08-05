defmodule Streamix.Queue.PublisherTest do
  use ExUnit.Case, async: true

  alias Streamix.Queue.Publisher

  test "builds one bounded task per GIndex scan root" do
    roots = [
      %{kind: :movies, path: "/1:/Movies/", base_url: "https://ignored.example"},
      %{kind: :series, path: "/1:/Series/"},
      %{kind: :animes, path: "/0:/Animes/"}
    ]

    assert {:ok, tasks} = Publisher.build_gindex_tasks(7, roots)

    assert tasks == [
             %{type: :gindex_movies, provider_id: 7, path: "/1:/Movies/"},
             %{type: :gindex_series, provider_id: 7, path: "/1:/Series/"},
             %{type: :gindex_animes, provider_id: 7, path: "/0:/Animes/"}
           ]

    refute Enum.any?(tasks, &Map.has_key?(&1, :base_url))
  end

  test "rejects invalid GIndex roots before publishing" do
    assert {:error, {:invalid_gindex_root, %{kind: :other, path: "/root/"}}} =
             Publisher.build_gindex_tasks(7, [%{kind: :other, path: "/root/"}])

    assert {:error, {:invalid_gindex_root, %{kind: :movies, path: " "}}} =
             Publisher.build_gindex_tasks(7, [%{kind: :movies, path: " "}])

    assert {:error, {:invalid_gindex_root, []}} = Publisher.build_gindex_tasks(0, [])
    assert {:error, :empty_gindex_roots} = Publisher.build_gindex_tasks(7, [])
  end

  test "validates task type and priorities before touching RabbitMQ" do
    assert {:error, {:unsupported_task_type, :unknown}} =
             Publisher.publish_sync_task(%{type: :unknown})

    assert {:error, {:invalid_priority, :urgent}} =
             Publisher.publish_sync_task(%{type: :iptv_movies}, priority: :urgent)

    assert {:error, {:invalid_message_priority, 11}} =
             Publisher.publish_sync_task(%{type: :iptv_movies}, message_priority: 11)
  end

  test "returns an encoding error instead of raising for an invalid payload" do
    assert {:error, :invalid_task_payload} =
             Publisher.publish_sync_task(%{
               type: :iptv_movies,
               provider_id: 7,
               invalid_value: self()
             })
  end

  test "reports batch failures instead of returning a false success" do
    tasks = [%{type: :unknown_a}, %{type: :unknown_b}]

    assert {:error,
            {:batch_publish_failed,
             %{
               success: 0,
               failed: 2,
               reasons: [
                 {:unsupported_task_type, :unknown_a},
                 {:unsupported_task_type, :unknown_b}
               ]
             }}} = Publisher.publish_batch(tasks)
  end

  test "rejects malformed folder batches before publishing" do
    assert {:error, :invalid_folder_tasks} =
             Publisher.enqueue_folder_tasks(7, [], :gindex_movies)

    assert {:error, :invalid_folder_tasks} =
             Publisher.enqueue_folder_tasks(7, ["/movies/"], :iptv_movies)

    assert {:error, :invalid_folder_tasks} =
             Publisher.enqueue_folder_tasks(7, [" "], :gindex_movies)
  end
end
