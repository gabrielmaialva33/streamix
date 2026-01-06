import { View, Text, type NodeProps, type IntrinsicNodeStyleProps } from '@lightningtv/solid';
import { Row } from '@lightningtv/solid/primitives';
import { createSignal, createEffect, For, Show } from 'solid-js';
import { useNavigate } from '@solidjs/router';
import { history, type HistoryItem } from '../lib/storage';
import { theme } from '../styles';

const CardStyle = {
  width: 320,
  height: 180,
  color: 0x1a1a2eff,
  borderRadius: 12,
  scale: 1,
  transition: {
    scale: { duration: 150, easing: 'ease-out' },
  },
  $focus: {
    scale: 1.05,
    border: { color: theme.primary, width: 3 },
  },
} satisfies IntrinsicNodeStyleProps;

const ProgressBarStyle = {
  height: 4,
  color: 0x444444ff,
  borderRadius: 2,
} satisfies IntrinsicNodeStyleProps;

export interface ContinueWatchingRowProps extends NodeProps {
  limit?: number;
}

const ContinueWatchingRow = (props: ContinueWatchingRowProps) => {
  const navigate = useNavigate();
  const [items, setItems] = createSignal<HistoryItem[]>([]);

  // Fetch history items
  createEffect(() => {
    const historyItems = history.getContinueWatching(props.limit || 10);
    setItems(historyItems);
  });

  const handleSelect = (item: HistoryItem) => {
    if (item.type === 'movie') {
      navigate(`/player/movie/${item.id}`);
    } else if (item.type === 'series' && item.episodeId) {
      navigate(`/player/series/${item.episodeId}`);
    } else if (item.type === 'channel') {
      navigate(`/player/channel/${item.id}`);
    }
  };

  const formatTime = (seconds: number) => {
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    if (h > 0) return `${h}h ${m}m restantes`;
    return `${m}m restantes`;
  };

  return (
    <View {...props} width={1700} height={280}>
      <Text x={20} fontSize={32} fontWeight="bold" color={0xffffffff}>
        Continue Assistindo
      </Text>

      <Show when={items().length === 0}>
        <View
          x={20}
          y={50}
          width={320}
          height={180}
          color={0x1a1a2eff}
          borderRadius={12}
          display="flex"
          justifyContent="center"
          alignItems="center"
        >
          <Text fontSize={16} color={0x666666ff}>
            Nenhum conteúdo em andamento
          </Text>
        </View>
      </Show>

      <Show when={items().length > 0}>
        <Row
          x={20}
          y={50}
          width={1660}
          height={200}
          gap={20}
          scroll="auto"
        >
          <For each={items()}>
            {(item) => (
              <View
                style={CardStyle}
                onEnter={() => handleSelect(item)}
                forwardStates
              >
                {/* Thumbnail/Poster */}
                <Show when={item.posterUrl}>
                  <View
                    width={120}
                    height={180}
                    src={item.posterUrl}
                    color={0xffffffff}
                    borderRadius={12}
                  />
                </Show>
                <Show when={!item.posterUrl}>
                  <View
                    width={120}
                    height={180}
                    color={0x2a2a3eff}
                    borderRadius={12}
                  />
                </Show>

                {/* Info */}
                <View x={130} y={10} width={180}>
                  <Text
                    fontSize={16}
                    fontWeight="bold"
                    color={0xffffffff}
                    contain="width"
                    width={180}
                    maxLines={2}
                  >
                    {item.title}
                  </Text>

                  {/* Episode info for series */}
                  <Show when={item.type === 'series' && item.episodeTitle}>
                    <Text
                      y={45}
                      fontSize={13}
                      color={0xaaaaaaff}
                      contain="width"
                      width={180}
                      maxLines={1}
                    >
                      S{item.seasonNumber}E{item.episodeNumber}
                    </Text>
                  </Show>

                  {/* Time remaining */}
                  <Text
                    y={item.type === 'series' ? 70 : 50}
                    fontSize={12}
                    color={0x888888ff}
                  >
                    {formatTime(item.duration - item.currentTime)}
                  </Text>
                </View>

                {/* Progress bar */}
                <View x={10} y={165} width={300}>
                  <View width={300} style={ProgressBarStyle}>
                    <View
                      width={Math.max(0, 300 * item.progress / 100)}
                      height={4}
                      color={theme.primary}
                      borderRadius={2}
                    />
                  </View>
                </View>
              </View>
            )}
          </For>
        </Row>
      </Show>
    </View>
  );
};

export default ContinueWatchingRow;
