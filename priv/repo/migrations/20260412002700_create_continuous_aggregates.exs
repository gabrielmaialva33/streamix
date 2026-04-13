defmodule Streamix.Repo.Migrations.CreateContinuousAggregates do
  use Ecto.Migration

  def up do
    # Hourly access stats — admin dashboard, traffic monitoring
    execute """
    CREATE MATERIALIZED VIEW access_stats_hourly
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', inserted_at) AS bucket,
      count(*) AS requests,
      count(user_id) AS auth_requests
    FROM access_logs
    GROUP BY bucket
    WITH NO DATA
    """

    execute """
    SELECT add_continuous_aggregate_policy('access_stats_hourly',
      start_offset => INTERVAL '3 hours',
      end_offset => INTERVAL '1 hour',
      schedule_interval => INTERVAL '1 hour')
    """

    # Daily access stats — hierarchical aggregate on hourly
    execute """
    CREATE MATERIALIZED VIEW access_stats_daily
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 day', bucket) AS bucket,
      sum(requests) AS requests,
      sum(auth_requests) AS auth_requests
    FROM access_stats_hourly
    GROUP BY time_bucket('1 day', bucket)
    WITH NO DATA
    """

    execute """
    SELECT add_continuous_aggregate_policy('access_stats_daily',
      start_offset => INTERVAL '3 days',
      end_offset => INTERVAL '1 day',
      schedule_interval => INTERVAL '1 day')
    """

    # Daily EPG coverage — programs per channel per day
    execute """
    CREATE MATERIALIZED VIEW epg_stats_daily
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 day', start_time) AS bucket,
      epg_channel_id,
      count(*) AS program_count
    FROM epg_programs
    GROUP BY bucket, epg_channel_id
    WITH NO DATA
    """

    execute """
    SELECT add_continuous_aggregate_policy('epg_stats_daily',
      start_offset => INTERVAL '3 days',
      end_offset => INTERVAL '1 day',
      schedule_interval => INTERVAL '1 day')
    """
  end

  def down do
    execute "DROP MATERIALIZED VIEW IF EXISTS access_stats_daily CASCADE"
    execute "DROP MATERIALIZED VIEW IF EXISTS access_stats_hourly CASCADE"
    execute "DROP MATERIALIZED VIEW IF EXISTS epg_stats_daily CASCADE"
  end
end
