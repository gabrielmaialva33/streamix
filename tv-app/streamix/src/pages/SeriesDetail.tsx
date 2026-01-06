import { View, Text, ElementNode, type IntrinsicNodeStyleProps } from '@lightningtv/solid';
import { Column, Row } from '@lightningtv/solid/primitives';
import { createSignal, createResource, For, Show } from 'solid-js';
import { useNavigate, useParams } from '@solidjs/router';
import { SkeletonLoader } from '../components';
import api, { type Episode, type Season } from '../lib/api';

// Style constants
const SeasonButtonStyle = {
  height: 50,
  borderRadius: 8,
  display: 'flex',
  justifyContent: 'center',
  alignItems: 'center',
  color: 0x333333ff,
  scale: 1,
  transition: {
    color: { duration: 150, easing: 'ease-out' },
    scale: { duration: 150, easing: 'ease-out' },
  },
  $focus: {
    color: 0xe50914ff,
    scale: 1.05,
  },
} satisfies IntrinsicNodeStyleProps;

const SelectedSeasonStyle = {
  ...SeasonButtonStyle,
  color: 0x555555ff,
} satisfies IntrinsicNodeStyleProps;

const EpisodeCardStyle = {
  width: 380,
  height: 120,
  borderRadius: 8,
  color: 0x222222ff,
  scale: 1,
  transition: {
    color: { duration: 150, easing: 'ease-out' },
    scale: { duration: 150, easing: 'ease-out' },
  },
  $focus: {
    color: 0x333333ff,
    scale: 1.02,
  },
} satisfies IntrinsicNodeStyleProps;

const SeriesDetail = () => {
  const navigate = useNavigate();
  const params = useParams<{ id: string }>();
  const [selectedSeasonIdx, setSelectedSeasonIdx] = createSignal(0);

  let seasonsRow: ElementNode | undefined;
  let episodesGrid: ElementNode | undefined;

  // Fetch series details
  const [series] = createResource(
    () => params.id,
    (id) => api.getSeriesDetail(id)
  );

  // Get current season's episodes
  const currentEpisodes = () => {
    const s = series();
    if (!s?.seasons?.length) return [];
    const season = s.seasons[selectedSeasonIdx()];
    return season?.episodes || [];
  };

  // Chunk episodes into rows of 4
  const episodeRows = () => {
    const eps = currentEpisodes();
    const rows: Episode[][] = [];
    for (let i = 0; i < eps.length; i += 4) {
      rows.push(eps.slice(i, i + 4));
    }
    return rows;
  };

  // Play episode - uses 'series' type which is handled as episode in Player
  const handlePlayEpisode = (episode: Episode) => {
    navigate(`/player/series/${episode.id}`);
  };

  // Handle back/left navigation
  const handleBack = () => {
    navigate('/series');
  };

  return (
    <View
      width={1700}
      height={1080}
      y={0}
      onLast={handleBack}
    >
      {/* Fixed Header - Series info */}
      <Show when={series.loading}>
        <View width={1700} height={280} skipFocus>
          <SkeletonLoader width={1660} height={250} x={20} borderRadius={12} />
        </View>
      </Show>

      <Show when={series()}>
        <View width={1700} height={280} x={0} y={0} skipFocus zIndex={10}>
          {/* Backdrop image */}
          <Show when={series()?.backdrop_url}>
            <View
              width={1700}
              height={280}
              src={series()?.backdrop_url}
              color={0x000000ff}
              zIndex={0}
            />
            {/* Gradient overlay */}
            <View
              width={1700}
              height={280}
              zIndex={1}
              shader={{
                type: 'linearGradient',
                colors: [0x0a0a0f00, 0x0a0a0fff],
                angle: 180,
              }}
            />
          </Show>

          {/* Series info overlay */}
          <View x={40} y={20} width={1600} height={240} zIndex={2}>
            {/* Poster */}
            <View
              width={130}
              height={195}
              src={series()?.poster_url || series()?.poster}
              color={0x333333ff}
              borderRadius={8}
            />

            {/* Text info */}
            <View x={160} y={0} width={1400}>
              <Text fontSize={36} fontWeight="bold" color={0xffffffff}>
                {series()?.title || series()?.name}
              </Text>
              <Text y={45} fontSize={18} color={0xaaaaaaff}>
                {[series()?.year, series()?.genre, `${series()?.season_count || series()?.seasons?.length || 0} temporadas`]
                  .filter(Boolean)
                  .join(' • ')}
              </Text>
              <Text
                y={75}
                width={1000}
                fontSize={16}
                color={0xccccccff}
                contain="width"
                maxLines={3}
              >
                {series()?.description || 'Sem descrição disponível.'}
              </Text>
            </View>
          </View>
        </View>
      </Show>

      {/* Scrollable content area - below header */}
      <Column
        x={0}
        y={290}
        width={1700}
        height={780}
        gap={16}
        scroll="none"
        clipping
      >
        {/* Seasons selector */}
        <Show when={series()?.seasons?.length}>
          <Row
            ref={seasonsRow}
            x={20}
            width={1660}
            height={60}
            gap={12}
            scroll="auto"
            autofocus
            onDown={() => episodesGrid?.setFocus()}
          >
            <For each={series()?.seasons}>
              {(season: Season & { season_number?: number }, idx) => (
                <View
                  width={150}
                  style={selectedSeasonIdx() === idx() ? SelectedSeasonStyle : SeasonButtonStyle}
                  onEnter={() => setSelectedSeasonIdx(idx())}
                >
                  <Text fontSize={18} color={0xffffffff}>
                    {`Temporada ${season.number ?? season.season_number ?? idx() + 1}`}
                  </Text>
                </View>
              )}
            </For>
          </Row>
        </Show>

        {/* Episodes grid */}
        <Column
          ref={episodesGrid}
          x={20}
          width={1660}
          height={700}
          gap={16}
          scroll="auto"
          plinko
          clipping
          onUp={() => seasonsRow?.setFocus()}
        >
          <Show when={episodeRows().length === 0 && !series.loading}>
            <View width={1640} height={200} display="flex" justifyContent="center" alignItems="center" skipFocus>
              <Text fontSize={24} color={0x888888ff}>Nenhum episódio disponível</Text>
            </View>
          </Show>

          <For each={episodeRows()}>
            {(row) => (
              <Row width={1640} height={130} gap={16} scroll="none">
                <For each={row}>
                  {(episode: Episode) => (
                    <View
                      style={EpisodeCardStyle}
                      onEnter={() => handlePlayEpisode(episode)}
                    >
                      {/* Episode thumbnail */}
                      <Show when={episode.thumbnail_url}>
                        <View
                          width={160}
                          height={90}
                          x={10}
                          y={15}
                          src={episode.thumbnail_url}
                          color={0x444444ff}
                          borderRadius={6}
                        />
                      </Show>

                      {/* Episode info */}
                      <View x={episode.thumbnail_url ? 180 : 15} y={15} width={180}>
                        <Text fontSize={16} fontWeight="bold" color={0xffffffff} maxLines={1}>
                          {`E${(episode as any).episode_num ?? episode.number ?? '?'}. ${episode.title || 'Episódio'}`}
                        </Text>
                        <Text y={25} fontSize={14} color={0xaaaaaaff} maxLines={2} contain="width">
                          {episode.description || ''}
                        </Text>
                        <Show when={episode.duration && !isNaN(episode.duration)}>
                          <Text y={70} fontSize={12} color={0x888888ff}>
                            {`${Math.floor((episode.duration || 0) / 60)} min`}
                          </Text>
                        </Show>
                      </View>
                    </View>
                  )}
                </For>
              </Row>
            )}
          </For>
        </Column>
      </Column>
    </View>
  );
};

export default SeriesDetail;
