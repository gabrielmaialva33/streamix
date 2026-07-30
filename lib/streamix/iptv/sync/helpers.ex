defmodule Streamix.Iptv.Sync.Helpers do
  @moduledoc """
  Backwards-compatible facade for shared sync helpers.
  """

  alias Streamix.Iptv.Sync.{
    CategoryAssocs,
    ContentUpsert,
    Metadata,
    OrphanCleanup,
    ValueParser
  }

  defdelegate batch_size(), to: ContentUpsert

  defdelegate parse_year(value), to: ValueParser
  defdelegate parse_decimal(value), to: ValueParser
  defdelegate parse_int(value), to: ValueParser
  defdelegate parse_date(value), to: ValueParser
  defdelegate to_string_or_nil(value), to: ValueParser

  defdelegate build_category_lookup(provider_id, type), to: CategoryAssocs, as: :build_lookup

  defdelegate rebuild_category_assocs_diff(catalog_item_ids, desired_assocs),
    to: CategoryAssocs,
    as: :rebuild_diff

  defdelegate build_category_assocs(streams, returned_entities, category_lookup, opts \\ []),
    to: CategoryAssocs,
    as: :build

  defdelegate upsert_content_batched(streams, provider_id, category_lookup, now, opts),
    to: ContentUpsert,
    as: :upsert_batched

  defdelegate pre_create_catalog_items(count, content_type, provider_id, now), to: ContentUpsert

  defdelegate delete_orphaned_content(provider_id, current_stream_ids, opts),
    to: OrphanCleanup,
    as: :delete

  defdelegate sync_genres_and_credits(
                streams,
                provider_id,
                schema,
                genre_join_table,
                fk_column,
                opts
              ),
              to: Metadata
end
