import { View, Text } from '@lightningtv/solid';
import { createSignal, createResource, onMount, onCleanup, Show } from 'solid-js';
import { useParams, useNavigate } from '@solidjs/router';
import api from '../lib/api';

declare const webapis: any;
declare const tizen: any;

type PlayerType = 'movie' | 'series' | 'channel';

interface PlayerState {
  playing: boolean;
  currentTime: number;
  duration: number;
  buffering: boolean;
  error: string | null;
}

const Player = () => {
  const params = useParams<{ type: PlayerType; id: string }>();
  const navigate = useNavigate();
  let videoRef: HTMLVideoElement | null = null;
  let controlsTimeout: number | null = null;

  const [state, setState] = createSignal<PlayerState>({
    playing: false,
    currentTime: 0,
    duration: 0,
    buffering: true,
    error: null,
  });

  const [showControls, setShowControls] = createSignal(true);
  const [title, setTitle] = createSignal('');

  // Fetch stream URL based on type
  const [streamData] = createResource(
    () => ({ type: params.type, id: params.id }),
    async ({ type, id }) => {
      try {
        let stream;
        let info;

        switch (type) {
          case 'movie':
            [stream, info] = await Promise.all([
              api.getMovieStream(id),
              api.getMovie(id),
            ]);
            setTitle(info.title);
            break;
          case 'series':
            [stream, info] = await Promise.all([
              api.getEpisodeStream(id),
              api.getEpisode(id),
            ]);
            setTitle(`S${info.season_number}E${info.number} - ${info.title}`);
            break;
          case 'channel':
            [stream, info] = await Promise.all([
              api.getChannelStream(id),
              api.getChannel(id),
            ]);
            setTitle(info.name);
            break;
          default:
            throw new Error('Unknown player type');
        }

        return stream;
      } catch (error) {
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

  // Initialize video element
  onMount(() => {
    // Create video element
    videoRef = document.createElement('video');
    videoRef.style.cssText = 'position:absolute;top:0;left:0;width:100%;height:100%;background:#000;z-index:-1;';
    document.body.appendChild(videoRef);

    // Event listeners
    videoRef.addEventListener('play', () => setState(s => ({ ...s, playing: true })));
    videoRef.addEventListener('pause', () => setState(s => ({ ...s, playing: false })));
    videoRef.addEventListener('waiting', () => setState(s => ({ ...s, buffering: true })));
    videoRef.addEventListener('playing', () => setState(s => ({ ...s, buffering: false })));
    videoRef.addEventListener('loadedmetadata', () => {
      setState(s => ({ ...s, duration: videoRef!.duration }));
    });
    videoRef.addEventListener('timeupdate', () => {
      setState(s => ({ ...s, currentTime: videoRef!.currentTime }));
    });
    videoRef.addEventListener('error', () => {
      setState(s => ({ ...s, error: 'Playback error', buffering: false }));
    });
    videoRef.addEventListener('ended', () => handleClose());

    // Keep screen awake on Tizen
    try {
      if (typeof webapis !== 'undefined' && webapis.avplay) {
        tizen.power.request('SCREEN', 'SCREEN_NORMAL');
      }
    } catch (e) {
      console.warn('Could not request screen power:', e);
    }

    resetControlsTimeout();
  });

  // Load video when stream URL is available
  createResource(
    () => streamData(),
    (data) => {
      if (data?.url && videoRef) {
        loadVideo(data.url);
      }
    }
  );

  const loadVideo = async (url: string) => {
    if (!videoRef) return;

    setState(s => ({ ...s, buffering: true, error: null }));

    try {
      // Check if HLS
      if (url.includes('.m3u8')) {
        // Use native HLS on Safari/Tizen
        if (videoRef.canPlayType('application/vnd.apple.mpegurl')) {
          videoRef.src = url;
        } else {
          // Dynamic import HLS.js for other browsers
          const Hls = (await import('hls.js')).default;
          if (Hls.isSupported()) {
            const hls = new Hls({
              enableWorker: true,
              lowLatencyMode: true,
            });
            hls.loadSource(url);
            hls.attachMedia(videoRef);
            hls.on(Hls.Events.ERROR, (_, data) => {
              if (data.fatal) {
                setState(s => ({ ...s, error: `HLS Error: ${data.type}` }));
              }
            });
          }
        }
      } else {
        // Direct playback for MP4/other formats
        videoRef.src = url;
      }

      await videoRef.play();
    } catch (error) {
      setState(s => ({ ...s, error: String(error), buffering: false }));
    }
  };

  // Cleanup
  onCleanup(() => {
    if (videoRef) {
      videoRef.pause();
      videoRef.remove();
    }
    if (controlsTimeout) clearTimeout(controlsTimeout);

    // Release screen power
    try {
      if (typeof tizen !== 'undefined') {
        tizen.power.release('SCREEN');
      }
    } catch (e) {}
  });

  // Format time
  const formatTime = (seconds: number) => {
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = Math.floor(seconds % 60);
    if (h > 0) {
      return `${h}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
    }
    return `${m}:${s.toString().padStart(2, '0')}`;
  };

  // Controls
  const togglePlayPause = () => {
    if (!videoRef) return;
    if (videoRef.paused) {
      videoRef.play();
    } else {
      videoRef.pause();
    }
    resetControlsTimeout();
  };

  const seek = (delta: number) => {
    if (!videoRef) return;
    videoRef.currentTime = Math.max(0, Math.min(state().duration, videoRef.currentTime + delta));
    resetControlsTimeout();
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
      color={0x000000ff}
      onEnter={togglePlayPause}
      onBack={handleClose}
      onLeft={() => seek(-10)}
      onRight={() => seek(10)}
      onUp={() => seek(60)}
      onDown={() => seek(-60)}
      onAny={resetControlsTimeout}
    >
      {/* Loading / Buffering */}
      <Show when={state().buffering}>
        <View
          width={1920}
          height={1080}
          display="flex"
          justifyContent="center"
          alignItems="center"
        >
          <Text fontSize={32} color={0xffffffff}>Carregando...</Text>
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
          <Text fontSize={28} color={0xe50914ff}>Erro de Reproducao</Text>
          <Text fontSize={20} color={0x888888ff}>{state().error}</Text>
        </View>
      </Show>

      {/* Controls Overlay */}
      <Show when={showControls()}>
        {/* Top Bar - Title */}
        <View
          y={0}
          width={1920}
          height={120}
          color={0x000000aa}
        >
          <Text
            x={60}
            y={40}
            fontSize={32}
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
          y={900}
          width={1920}
          height={180}
          color={0x000000aa}
        >
          {/* Progress Bar */}
          <View x={60} y={60} width={1800} height={8} color={0x444444ff} borderRadius={4}>
            <View
              width={1800 * progress() / 100}
              height={8}
              color={0xe50914ff}
              borderRadius={4}
            />
          </View>

          {/* Time */}
          <View x={60} y={80}>
            <Text fontSize={20} color={0xffffffff}>
              {formatTime(state().currentTime)} / {formatTime(state().duration)}
            </Text>
          </View>

          {/* Play/Pause indicator */}
          <View x={1800} y={80}>
            <Text fontSize={20} color={0x888888ff}>
              {state().playing ? 'Pause' : 'Play'}
            </Text>
          </View>

          {/* Controls hint */}
          <View x={60} y={120} display="flex" gap={40}>
            <Text fontSize={16} color={0x666666ff}>Esquerda -10s</Text>
            <Text fontSize={16} color={0x666666ff}>Direita +10s</Text>
            <Text fontSize={16} color={0x666666ff}>Cima +1m</Text>
            <Text fontSize={16} color={0x666666ff}>Baixo -1m</Text>
            <Text fontSize={16} color={0x666666ff}>OK Play/Pause</Text>
            <Text fontSize={16} color={0x666666ff}>Voltar Sair</Text>
          </View>
        </View>
      </Show>
    </View>
  );
};

export default Player;
