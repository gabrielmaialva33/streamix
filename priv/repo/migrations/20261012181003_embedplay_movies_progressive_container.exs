defmodule Streamix.Repo.Migrations.EmbedplayMoviesProgressiveContainer do
  use Ecto.Migration

  # No DDL: a scoped data UPDATE on EmbedPlay movies only.
  #
  # EmbedPlay's only usable upstream now delivers one progressive MP4 per movie,
  # and Streamix serves it from `/api/stream/embedplay/video.mp4`. The web
  # player derives `data-stream-type` from `container_extension` and picks its
  # engine from it before fetching anything; left at `m3u8`, it would hand the
  # MP4 URL to hls.js. New imports already write `mp4`.

  def up do
    execute("""
    UPDATE movies AS movie
    SET container_extension = 'mp4'
    FROM providers AS provider
    WHERE provider.id = movie.provider_id
      AND provider.provider_type = 'embedplay'
      AND movie.container_extension = 'm3u8'
    """)
  end

  # Every EmbedPlay movie was imported as `m3u8` before this change, so the
  # previous value is known exactly.
  def down do
    execute("""
    UPDATE movies AS movie
    SET container_extension = 'm3u8'
    FROM providers AS provider
    WHERE provider.id = movie.provider_id
      AND provider.provider_type = 'embedplay'
      AND movie.container_extension = 'mp4'
    """)
  end
end
