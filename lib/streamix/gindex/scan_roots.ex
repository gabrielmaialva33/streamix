defmodule Streamix.Gindex.ScanRoots do
  @moduledoc false

  import Ecto.Query

  alias Streamix.Gindex.ScanRoot
  alias Streamix.Repo

  @active_statuses ~w(pending running paused)
  @terminal_statuses ~w(completed failed)

  @type root_spec :: %{
          required(:base_url) => String.t(),
          required(:path) => String.t(),
          required(:kind) => :movies | :series | :animes
        }

  @doc "Ensures one durable cycle exists for the configured roots."
  @spec ensure_cycle(pos_integer(), [root_spec()], keyword()) ::
          {:ok, %{cycle_id: Ecto.UUID.t(), new_cycle?: boolean(), roots: [ScanRoot.t()]}}
          | {:error, term()}
  def ensure_cycle(provider_id, roots, opts \\ []) when is_list(roots) do
    Repo.transaction(fn ->
      existing = list_provider_roots(provider_id)
      requested_cycle_id = Keyword.get(opts, :cycle_id)
      active_cycle_id = find_active_cycle(existing, roots)
      cycle_id = requested_cycle_id || active_cycle_id || Ecto.UUID.generate()
      new_cycle? = is_nil(requested_cycle_id) and is_nil(active_cycle_id)
      legacy_checkpoints = Keyword.get(opts, :legacy_checkpoints, %{})
      now = DateTime.utc_now()

      durable_roots =
        roots
        |> Enum.with_index()
        |> Enum.map(fn {root, position} ->
          key = identity(root.path, root.kind)
          current = Enum.find(existing, &(identity(&1.root_path, &1.kind) == key))

          persist_cycle_root(
            current,
            provider_id,
            root,
            position,
            cycle_id,
            now,
            Map.get(legacy_checkpoints, key)
          )
        end)

      %{cycle_id: cycle_id, new_cycle?: new_cycle?, roots: durable_roots}
    end)
  end

  @doc "Returns the durable row for a configured root."
  @spec get(pos_integer(), String.t(), atom() | String.t()) :: ScanRoot.t() | nil
  def get(provider_id, path, kind) do
    Repo.get_by(ScanRoot,
      provider_id: provider_id,
      root_path: path,
      kind: normalize_kind(kind)
    )
  end

  @doc "Lists all roots participating in a cycle, in dispatch order."
  @spec list_cycle(pos_integer(), Ecto.UUID.t()) :: [ScanRoot.t()]
  def list_cycle(provider_id, cycle_id) do
    ScanRoot
    |> where(provider_id: ^provider_id, cycle_id: ^cycle_id)
    |> order_by(asc: :position, asc: :id)
    |> Repo.all()
  end

  @doc "Returns the newest unfinished cycle for a provider."
  @spec active_cycle_id(pos_integer()) :: Ecto.UUID.t() | nil
  def active_cycle_id(provider_id) do
    ScanRoot
    |> where([root], root.provider_id == ^provider_id and root.status in ^@active_statuses)
    |> order_by([root], desc: root.updated_at)
    |> limit(1)
    |> select([root], root.cycle_id)
    |> Repo.one()
  end

  @doc "Returns the most recently touched cycle, including settled cycles."
  @spec latest_cycle_id(pos_integer()) :: Ecto.UUID.t() | nil
  def latest_cycle_id(provider_id) do
    ScanRoot
    |> where(provider_id: ^provider_id)
    |> order_by(desc: :updated_at)
    |> limit(1)
    |> select([root], root.cycle_id)
    |> Repo.one()
  end

  @doc "Marks a root as executing and advances its durable heartbeat."
  @spec mark_running(ScanRoot.t()) :: {:ok, ScanRoot.t()} | {:error, Ecto.Changeset.t()}
  def mark_running(%ScanRoot{} = root) do
    now = DateTime.utc_now()

    persist_update(root, %{
      status: "running",
      paused_reason: nil,
      quota_count: nil,
      next_resume_at: nil,
      last_error: nil,
      last_progress_at: now,
      started_at: root.started_at || now,
      attempt_count: root.attempt_count + 1
    })
  end

  @doc "Persists a cursor only after the corresponding batch is durable."
  @spec checkpoint(ScanRoot.t(), map()) :: {:ok, ScanRoot.t()} | {:error, Ecto.Changeset.t()}
  def checkpoint(%ScanRoot{} = root, cursor) when is_map(cursor) do
    persist_update(root, %{
      status: "running",
      cursor: stringify_map(cursor),
      paused_reason: nil,
      next_resume_at: nil,
      last_progress_at: DateTime.utc_now()
    })
  end

  @doc "Records a cooperative or quota pause without losing the cursor."
  @spec mark_paused(ScanRoot.t(), atom() | String.t(), keyword()) ::
          {:ok, ScanRoot.t()} | {:error, Ecto.Changeset.t()}
  def mark_paused(%ScanRoot{} = root, reason, opts \\ []) do
    persist_update(root, %{
      status: "paused",
      paused_reason: to_string(reason),
      quota_count: Keyword.get(opts, :quota_count),
      next_resume_at: Keyword.get(opts, :next_resume_at),
      last_error: error_payload(Keyword.get(opts, :error)),
      last_progress_at: DateTime.utc_now()
    })
  end

  @doc "Completes a root and clears its no-longer-needed cursor."
  @spec mark_completed(ScanRoot.t(), map()) ::
          {:ok, ScanRoot.t()} | {:error, Ecto.Changeset.t()}
  def mark_completed(%ScanRoot{} = root, stats) do
    now = DateTime.utc_now()

    persist_update(root, %{
      status: "completed",
      cursor: %{},
      stats: stringify_map(stats),
      paused_reason: nil,
      quota_count: nil,
      next_resume_at: nil,
      last_error: nil,
      completed_at: now,
      last_progress_at: now
    })
  end

  @doc "Marks a root terminally failed after its Oban retry budget is exhausted."
  @spec mark_failed(ScanRoot.t(), term()) ::
          {:ok, ScanRoot.t()} | {:error, Ecto.Changeset.t()}
  def mark_failed(%ScanRoot{} = root, reason) do
    now = DateTime.utc_now()

    persist_update(root, %{
      status: "failed",
      paused_reason: nil,
      quota_count: nil,
      next_resume_at: nil,
      last_error: error_payload(reason),
      completed_at: now,
      last_progress_at: now
    })
  end

  @doc "Summarizes a cycle independently from Oban's retention window."
  @spec cycle_summary(pos_integer(), Ecto.UUID.t()) :: map()
  def cycle_summary(provider_id, cycle_id) do
    roots = list_cycle(provider_id, cycle_id)
    status_counts = Enum.frequencies_by(roots, & &1.status)

    %{
      cycle_id: cycle_id,
      roots_total: length(roots),
      roots_completed: Map.get(status_counts, "completed", 0),
      roots_failed: Map.get(status_counts, "failed", 0),
      roots_pending: Map.get(status_counts, "pending", 0),
      roots_running: Map.get(status_counts, "running", 0),
      roots_paused: Map.get(status_counts, "paused", 0),
      roots_paused_quota: Enum.count(roots, &(&1.paused_reason == "quota_exhausted")),
      roots_paused_upstream: Enum.count(roots, &(&1.paused_reason == "upstream_rate_limited")),
      roots_with_skips: Enum.count(roots, &positive_stat?(&1.stats, "skipped_count")),
      roots_unfinished: Enum.count(roots, &(&1.status in @active_statuses)),
      settled?: roots != [] and Enum.all?(roots, &(&1.status in @terminal_statuses)),
      heartbeat_at: latest_datetime(roots, :last_progress_at),
      next_resume_at: earliest_datetime(roots, :next_resume_at)
    }
  end

  defp list_provider_roots(provider_id) do
    ScanRoot
    |> where(provider_id: ^provider_id)
    |> order_by(desc: :updated_at)
    |> Repo.all()
  end

  defp find_active_cycle(existing, roots) do
    identities = MapSet.new(roots, &identity(&1.path, &1.kind))

    existing
    |> Enum.find(fn root ->
      root.status in @active_statuses and
        MapSet.member?(identities, identity(root.root_path, root.kind))
    end)
    |> case do
      nil -> nil
      root -> root.cycle_id
    end
  end

  defp persist_cycle_root(
         %ScanRoot{cycle_id: cycle_id} = root,
         _provider_id,
         spec,
         position,
         cycle_id,
         _now,
         legacy_checkpoint
       ) do
    attrs = %{base_url: spec.base_url, position: position}

    attrs =
      if root.cursor == %{} and is_map(legacy_checkpoint) do
        Map.put(attrs, :cursor, stringify_map(legacy_checkpoint))
      else
        attrs
      end

    update!(root, attrs)
  end

  defp persist_cycle_root(root, provider_id, spec, position, cycle_id, now, legacy_checkpoint) do
    attrs = %{
      provider_id: provider_id,
      base_url: spec.base_url,
      root_path: spec.path,
      kind: normalize_kind(spec.kind),
      position: position,
      cycle_id: cycle_id,
      status: "pending",
      cursor: if(is_map(legacy_checkpoint), do: stringify_map(legacy_checkpoint), else: %{}),
      stats: %{},
      last_error: nil,
      paused_reason: nil,
      quota_count: nil,
      next_resume_at: nil,
      started_at: now,
      completed_at: nil,
      last_progress_at: now,
      attempt_count: 0
    }

    case root do
      nil -> %ScanRoot{} |> ScanRoot.changeset(attrs) |> Repo.insert!()
      %ScanRoot{} -> update!(root, attrs)
    end
  end

  defp persist_update(%ScanRoot{id: id}, attrs) do
    ScanRoot
    |> Repo.get!(id)
    |> ScanRoot.changeset(attrs)
    |> Repo.update()
  end

  defp update!(root, attrs), do: root |> ScanRoot.changeset(attrs) |> Repo.update!()

  defp identity(path, kind), do: {path, normalize_kind(kind)}
  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind) when is_binary(kind), do: kind

  defp stringify_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)

  defp stringify_value(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&stringify_value/1)
  end

  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value

  defp error_payload(nil), do: nil

  defp error_payload({:partial_listing, details}) when is_map(details) do
    %{
      "reason" => "partial_listing",
      "details" => details |> Map.drop([:items, "items"]) |> stringify_map()
    }
  end

  defp error_payload(reason) do
    %{"reason" => inspect(reason, limit: 20, printable_limit: 1_000)}
  end

  defp positive_stat?(stats, key) when is_map(stats), do: Map.get(stats, key, 0) > 0
  defp positive_stat?(_stats, _key), do: false

  defp latest_datetime(roots, field) do
    roots
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp earliest_datetime(roots, field) do
    roots
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
  end
end
