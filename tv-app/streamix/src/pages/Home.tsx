import { View, Text } from '@lightningtv/solid';
import { Column } from '@lightningtv/solid/primitives';
import { createSignal, createResource, For, Show, onMount } from 'solid-js';
import { useNavigate } from '@solidjs/router';
import { Card, ContentRow, Hero } from '../components';
import api, { type FeaturedItem, type Movie, type Series } from '../lib/api';

const Home = () => {
  const navigate = useNavigate();
  const [featuredIndex, setFeaturedIndex] = createSignal(0);

  // Fetch data
  const [featured] = createResource(() => api.getFeatured());
  const [movies] = createResource(() => api.getMovies({ limit: 20 }));
  const [series] = createResource(() => api.getSeries({ limit: 20 }));

  // Auto-rotate featured
  onMount(() => {
    const interval = setInterval(() => {
      const items = featured();
      if (items && items.length > 1) {
        setFeaturedIndex(i => (i + 1) % items.length);
      }
    }, 8000);
    return () => clearInterval(interval);
  });

  const currentFeatured = () => {
    const items = featured();
    return items?.[featuredIndex()];
  };

  const handlePlayFeatured = () => {
    const item = currentFeatured();
    if (!item) return;

    if (item.type === 'movie') {
      navigate(`/player/movie/${item.id}`);
    } else if (item.type === 'series') {
      navigate(`/series/${item.id}`);
    } else if (item.type === 'channel') {
      navigate(`/player/channel/${item.id}`);
    }
  };

  const handleInfoFeatured = () => {
    const item = currentFeatured();
    if (!item) return;

    if (item.type === 'movie') {
      navigate(`/movie/${item.id}`);
    } else if (item.type === 'series') {
      navigate(`/series/${item.id}`);
    }
  };

  return (
    <Column
      x={220}
      width={1700}
      height={1080}
      gap={30}
      scroll="always"
    >
      {/* Hero Section */}
      <Hero
        item={currentFeatured()}
        onPlay={handlePlayFeatured}
        onInfo={handleInfoFeatured}
      />

      {/* Movies Row */}
      <Show when={movies()?.data?.length}>
        <ContentRow
          title="Filmes Populares"
          onSelectedChanged={(index) => {
            const movie = movies()?.data?.[index];
            if (movie) api.prefetchMovie(String(movie.id));
          }}
        >
          <For each={movies()?.data}>
            {(movie: Movie) => (
              <Card
                title={movie.title || movie.name}
                imageUrl={movie.poster_url || movie.poster}
                subtitle={movie.year?.toString()}
                onEnter={() => navigate(`/movie/${movie.id}`)}
              />
            )}
          </For>
        </ContentRow>
      </Show>

      {/* Series Row */}
      <Show when={series()?.data?.length}>
        <ContentRow
          title="Series Populares"
          onSelectedChanged={(index) => {
            const show = series()?.data?.[index];
            if (show) api.prefetchSeries(String(show.id));
          }}
        >
          <For each={series()?.data}>
            {(show: Series) => (
              <Card
                title={show.title || show.name}
                imageUrl={show.poster_url || show.poster}
                subtitle={show.year?.toString()}
                onEnter={() => navigate(`/series/${show.id}`)}
              />
            )}
          </For>
        </ContentRow>
      </Show>

      {/* Continue Watching Row (placeholder) */}
      <ContentRow title="Continue Assistindo">
        <View width={240} height={420} color={0x1a1a2eff} borderRadius={12}>
          <View
            width={240}
            height={360}
            color={0x2a2a3eff}
            borderRadius={12}
            display="flex"
            justifyContent="center"
            alignItems="center"
          >
            <View width={200} height={300}>
              <View
                y={100}
                width={200}
                height={100}
                display="flex"
                flexDirection="column"
                alignItems="center"
                gap={10}
              >
                <Text fontSize={18} color={0x888888ff}>Sem conteudo</Text>
              </View>
            </View>
          </View>
        </View>
      </ContentRow>
    </Column>
  );
};

export default Home;
