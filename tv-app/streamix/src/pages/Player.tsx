import { View, Text } from '@lightningtv/solid';
import { createSignal, createResource, onMount, onCleanup, Show, createEffect } from 'solid-js';
import { useParams, useNavigate } from '@solidjs/router';
import api from '../lib/api';
import { history } from '../lib/storage';
import PlayerManager, { type PlayerState } from '../managers/PlayerManager';
import { theme } from '../styles';

type PlayerType = 'movie' | 'series' | 'channel';

/**
 * Get the appropriate stream URL based on the platform
 * Priority: browser_stream_url > stream_url
 *
 * Note: We prefer browser_stream_url even on Tizen because:
 * - The Phoenix proxy (stream_url) doesn't respond without Range header
 * - AVPlay makes initial requests without Range, causing PLAYER_ERROR_CONNECTION_FAILED
 * - browser_stream_url (pannxs proxy) works correctly with AVPlay
 */
const getStreamUrl = (info: any, _isBrowser: boolean): string => {
  // Prefer browser_stream_url for all platforms (it works without Range header)
  if (info.browser_stream_url) {
    console.log('[Player] Using browser stream URL (pannxs proxy)');
    return info.browser_stream_url;
  }
  console.log('[Player] Using stream_url (Phoenix proxy)');
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
  const [controlsAlpha, setControlsAlpha] = createSignal(1);
  const [title, setTitle] = createSignal('');
  const [posterUrl, setPosterUrl] = createSignal<string | undefined>();
  const [seekFeedback, setSeekFeedback] = createSignal<string | null>(null);
  const [accumulatedSeek, setAccumulatedSeek] = createSignal(0);
  let seekFeedbackTimeout: number | null = null;
  let historyInterval: number | null = null;

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
            setPosterUrl(info.poster_url || info.poster);
            break;
          case 'series':
            info = await api.getEpisode(id);
            setTitle(`S${info.season_number}E${info.episode_num} - ${info.title}`);
            setPosterUrl(info.thumbnail_url);
            break;
          case 'channel':
            info = await api.getChannel(id);
            setTitle(info.name || 'Channel');
            setPosterUrl(info.logo_url || info.icon);
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

  // Hide controls after inactivity with fade animation
  const resetControlsTimeout = () => {
    if (controlsTimeout) clearTimeout(controlsTimeout);
    setShowControls(true);
    setControlsAlpha(1);

    controlsTimeout = window.setTimeout(() => {
      if (state().playing) {
        // Fade out animation
        let alpha = 1;
        const fadeInterval = setInterval(() => {
          alpha -= 0.1;
          if (alpha <= 0) {
            clearInterval(fadeInterval);
            setShowControls(false);
            setControlsAlpha(1);
          } else {
            setControlsAlpha(alpha);
          }
        }, 50);
      }
    }, 4500);
  };

  // Save watch history periodically
  const saveHistory = () => {
    const { currentTime, duration } = state();
    if (duration <= 0) return;

    const progress = Math.min(100, (currentTime / duration) * 100);

    history.update({
      id: params.id,
      type: params.type,
      title: title(),
      posterUrl: posterUrl(),
      progress,
      currentTime,
      duration,
    });
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

    // Save history every 10 seconds
    historyInterval = window.setInterval(saveHistory, 10000);
  });

  // Cleanup - CRITICAL for memory management
  onCleanup(() => {
    console.log('[Player] Cleanup');
    if (controlsTimeout) clearTimeout(controlsTimeout);
    if (seekFeedbackTimeout) clearTimeout(seekFeedbackTimeout);
    if (historyInterval) clearInterval(historyInterval);

    // Save final progress before leaving
    saveHistory();

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

    // Accumulate seek for visual feedback
    const newAccumulated = accumulatedSeek() + delta;
    setAccumulatedSeek(newAccumulated);

    // Show seek feedback
    const sign = newAccumulated >= 0 ? '+' : '';
    if (Math.abs(newAccumulated) >= 60) {
      const mins = Math.floor(Math.abs(newAccumulated) / 60);
      const secs = Math.abs(newAccumulated) % 60;
      setSeekFeedback(`${sign}${newAccumulated >= 0 ? '' : '-'}${mins}m${secs > 0 ? ` ${secs}s` : ''}`);
    } else {
      setSeekFeedback(`${sign}${newAccumulated}s`);
    }

    // Clear previous timeout and set new one
    if (seekFeedbackTimeout) clearTimeout(seekFeedbackTimeout);
    seekFeedbackTimeout = window.setTimeout(() => {
      // Execute the accumulated seek
      PlayerManager.seek(accumulatedSeek());
      setSeekFeedback(null);
      setAccumulatedSeek(0);
    }, 800);
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

      {/* Seek Feedback - Center of screen */}
      <Show when={seekFeedback()}>
        <View
          width={1920}
          height={1080}
          display="flex"
          justifyContent="center"
          alignItems="center"
          zIndex={100}
        >
          <View
            width={200}
            height={100}
            color={0x000000aa}
            borderRadius={16}
            display="flex"
            justifyContent="center"
            alignItems="center"
          >
            <Text fontSize={42} fontWeight="bold" color={theme.primary}>
              {seekFeedback()}
            </Text>
          </View>
        </View>
      </Show>

      {/* Controls Overlay with fade animation */}
      <Show when={showControls() && !state().error}>
        {/* Top Bar - Title */}
        <View
          y={0}
          width={1920}
          height={120}
          color={0x333333ee}
          alpha={controlsAlpha()}
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
          alpha={controlsAlpha()}
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
