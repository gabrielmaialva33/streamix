import { View, Text } from '@lightningtv/solid';
import { createSignal, createResource, onMount, onCleanup, Show, createEffect } from 'solid-js';
import { useParams, useNavigate } from '@solidjs/router';
import api from '../lib/api';
import PlayerManager, { type PlayerState } from '../managers/PlayerManager';

type PlayerType = 'movie' | 'series' | 'channel';

/**
 * Get the appropriate stream URL based on the platform
 * - Tizen AVPlay: uses stream_url (token-based proxy)
 * - Browser: uses browser_stream_url (pannxs proxy with CORS support)
 */
const getStreamUrl = (info: any, isBrowser: boolean): string => {
  if (isBrowser && info.browser_stream_url) {
    console.log('[Player] Using browser stream URL');
    return info.browser_stream_url;
  }
  return info.stream_url;
};

const Player = () => {
  const params = useParams<{ type: PlayerType; id: string }>();
  const navigate = useNavigate();

  let controlsTimeout: number | null = null;

  const [state, setState] = createSignal<PlayerState>({
    playing: false,
    currentTime: 0,
    duration: 0,
    buffering: true,
    error: null,
    ready: false,
  });

  const [showControls, setShowControls] = createSignal(true);
  const [title, setTitle] = createSignal('');

  // Fetch stream URL based on type
  const [streamData] = createResource(
    () => ({ type: params.type, id: params.id }),
    async ({ type, id }) => {
      try {
        let info: any;

        switch (type) {
          case 'movie':
            info = await api.getMovie(id);
            setTitle(info.title || info.name || 'Movie');
            break;
          case 'series':
            info = await api.getEpisode(id);
            setTitle(`S${info.season_number}E${info.episode_num} - ${info.title}`);
            break;
          case 'channel':
            info = await api.getChannel(id);
            setTitle(info.name || 'Channel');
            break;
          default:
            throw new Error('Unknown player type');
        }

        // Determine if running in browser (not Tizen)
        const isBrowser = !PlayerManager.hasAVPlay();

        // Use stream_url from info if available, otherwise fetch separately
        let streamUrl = getStreamUrl(info, isBrowser);
        if (!streamUrl) {
          // Fallback to stream endpoint
          const stream = type === 'movie' ? await api.getMovieStream(id)
            : type === 'series' ? await api.getEpisodeStream(id)
            : await api.getChannelStream(id);
          console.log('[Player] Stream from endpoint:', stream);
          streamUrl = getStreamUrl(stream, isBrowser);
        }

        console.log('[Player] Stream URL:', streamUrl, { isBrowser });
        return { stream_url: streamUrl };
      } catch (error) {
        console.error('[Player] Error fetching stream:', error);
        setState(s => ({ ...s, error: String(error), buffering: false }));
        throw error;
      }
    }
  );

  // Hide controls after inactivity
  const resetControlsTimeout = () => {
    if (controlsTimeout) clearTimeout(controlsTimeout);
    setShowControls(true);
    controlsTimeout = window.setTimeout(() => {
      if (state().playing) setShowControls(false);
    }, 5000);
  };

  // Initialize player when stream data is available
  createEffect(() => {
    const data = streamData();
    if (data?.stream_url) {
      console.log('[Player] Loading stream:', data.stream_url);

      // Initialize player manager with callbacks
      PlayerManager.init({
        onStateChange: (newState) => {
          setState(newState);
        },
        onComplete: () => {
          console.log('[Player] Playback complete');
          handleClose();
        },
        onError: (error) => {
          console.error('[Player] Error:', error);
        },
      }).then(() => {
        // Load the stream
        PlayerManager.load(data.stream_url);
      });
    }
  });

  onMount(() => {
    console.log('[Player] Mounted');
    resetControlsTimeout();
  });

  // Cleanup - CRITICAL for memory management
  onCleanup(() => {
    console.log('[Player] Cleanup');
    if (controlsTimeout) clearTimeout(controlsTimeout);
    PlayerManager.destroy();
  });

  // Format time
  const formatTime = (seconds: number) => {
    if (!seconds || !isFinite(seconds)) return '0:00';
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = Math.floor(seconds % 60);
    if (h > 0) {
      return `${h}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
    }
    return `${m}:${s.toString().padStart(2, '0')}`;
  };

  // Controls
  const handlePlayPause = () => {
    resetControlsTimeout();
    PlayerManager.togglePlayPause();
  };

  const handleSeek = (delta: number) => {
    resetControlsTimeout();
    PlayerManager.seek(delta);
  };

  const handleClose = () => {
    navigate(-1);
  };

  // Calculate progress percentage
  const progress = () => {
    const { currentTime, duration } = state();
    return duration > 0 ? (currentTime / duration) * 100 : 0;
  };

  return (
    <View
      x={0}
      y={0}
      width={1920}
      height={1080}
      color={0x00000000}
      onEnter={handlePlayPause}
      onBack={handleClose}
      onLeft={() => handleSeek(-10)}
      onRight={() => handleSeek(10)}
      onUp={() => handleSeek(60)}
      onDown={() => handleSeek(-60)}
      onAny={resetControlsTimeout}
      autofocus
    >
      {/* Loading / Buffering */}
      <Show when={state().buffering && !state().error}>
        <View
          width={1920}
          height={1080}
          display="flex"
          justifyContent="center"
          alignItems="center"
        >
          <Text fontSize={36} color={0xffffffff}>Carregando...</Text>
        </View>
      </Show>

      {/* Error */}
      <Show when={state().error}>
        <View
          width={1920}
          height={1080}
          display="flex"
          flexDirection="column"
          justifyContent="center"
          alignItems="center"
          gap={20}
        >
          <Text fontSize={32} color={0xe50914ff}>Erro de Reproducao</Text>
          <Text fontSize={24} color={0x888888ff}>{state().error}</Text>
          <Text fontSize={20} color={0x666666ff} y={40}>Pressione Voltar para sair</Text>
        </View>
      </Show>

      {/* Controls Overlay */}
      <Show when={showControls() && !state().error}>
        {/* Top Bar - Title */}
        <View
          y={0}
          width={1920}
          height={120}
          color={0x333333ee}
        >
          <Text
            x={60}
            y={40}
            fontSize={36}
            fontWeight="bold"
            color={0xffffffff}
            contain="width"
            width={1800}
            textOverflow="ellipsis"
            maxLines={1}
          >
            {title()}
          </Text>
        </View>

        {/* Bottom Bar - Progress & Controls */}
        <View
          y={880}
          width={1920}
          height={200}
          color={0x333333ee}
        >
          {/* Progress Bar Background */}
          <View x={60} y={40} width={1800} height={8} color={0x444444ff} borderRadius={4}>
            {/* Progress Bar Fill */}
            <View
              width={Math.max(0, 1800 * progress() / 100)}
              height={8}
              color={0xe50914ff}
              borderRadius={4}
            />
          </View>

          {/* Time */}
          <View x={60} y={60}>
            <Text fontSize={24} color={0xffffffff}>
              {formatTime(state().currentTime)} / {formatTime(state().duration)}
            </Text>
          </View>

          {/* Play/Pause indicator */}
          <View x={1760} y={60}>
            <Text fontSize={24} color={0xccccccff}>
              {state().playing ? 'II Pause' : '> Play'}
            </Text>
          </View>

          {/* Controls hint */}
          <View x={60} y={110} display="flex" gap={50}>
            <Text fontSize={18} color={0x888888ff}>{'<'} -10s</Text>
            <Text fontSize={18} color={0x888888ff}>{'>'} +10s</Text>
            <Text fontSize={18} color={0x888888ff}>^ +1min</Text>
            <Text fontSize={18} color={0x888888ff}>v -1min</Text>
            <Text fontSize={18} color={0x888888ff}>OK Play/Pause</Text>
            <Text fontSize={18} color={0x888888ff}>Voltar Sair</Text>
          </View>
        </View>
      </Show>
    </View>
  );
};

export default Player;
