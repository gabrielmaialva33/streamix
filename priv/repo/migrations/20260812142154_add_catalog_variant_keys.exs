defmodule Streamix.Repo.Migrations.AddCatalogVariantKeys do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :variant_key, :string,
        size: 512,
        generated: movie_variant_key()
    end

    alter table(:series) do
      add :variant_key, :string,
        size: 512,
        generated: series_variant_key()
    end
  end

  # Keep these immutable expressions in the migration: changing application
  # code later must never change the meaning of an already-applied migration.
  defp movie_variant_key do
    """
    ALWAYS AS (CASE
      WHEN nullif(tmdb_id, '') IS NOT NULL THEN 'tmdb:' || tmdb_id
      WHEN regexp_replace(lower(coalesce(title, name)), '[^[:alnum:]]+', '', 'g') = '18xxx'
        THEN 'item:' || id::text
      ELSE 'title:' ||
        lower(
          btrim(
            regexp_replace(
              regexp_replace(
                regexp_replace(
                  regexp_replace(
                    coalesce(title, name),
                    '\\s*\\[[^\\]]+\\]',
                    ' ',
                    'g'
                  ),
                  '\\m(4k|2160p|1080p|720p|hdr10|hdr|dublado|legendado|dual audio|dual-audio|dub|leg|x264|x265|h264|h265|hevc|web-dl|webrip|bluray|blu-ray)\\M',
                  ' ',
                  'gi'
                ),
                '[[:punct:]]+',
                ' ',
                'g'
              ),
              '\\s+',
              ' ',
              'g'
            )
          )
        ) || ':' || coalesce(year::text, '')
    END) STORED
    """
  end

  defp series_variant_key do
    """
    ALWAYS AS (CASE
      WHEN nullif(tmdb_id, '') IS NOT NULL THEN 'tmdb:' || tmdb_id
      ELSE 'title:' ||
        lower(
          btrim(
            regexp_replace(
              regexp_replace(
                regexp_replace(
                  regexp_replace(
                    coalesce(title, name),
                    '\\s*\\[[^\\]]+\\]',
                    ' ',
                    'g'
                  ),
                  '\\m(4k|2160p|1080p|720p|hdr10|hdr|dublado|legendado|dual audio|dual-audio|dub|leg|x264|x265|h264|h265|hevc|web-dl|webrip|bluray|blu-ray)\\M',
                  ' ',
                  'gi'
                ),
                '[[:punct:]]+',
                ' ',
                'g'
              ),
              '\\s+',
              ' ',
              'g'
            )
          )
        ) || ':' || coalesce(year::text, '')
    END) STORED
    """
  end
end
