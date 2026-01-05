import { View, Text, ElementNode } from '@lightningtv/solid';
import { Column, Row } from '@lightningtv/solid/primitives';
import { createSignal, createResource, For, Show } from 'solid-js';
import { useNavigate } from '@solidjs/router';
import { Card, SearchBox } from '../components';
import api, { type Movie, type Category } from '../lib/api';

const ITEMS_PER_ROW = 6;
const ITEMS_PER_PAGE = 30;

const Movies = () => {
  const navigate = useNavigate();
  const [selectedCategory, setSelectedCategory] = createSignal<string | undefined>(undefined);
  const [offset, setOffset] = createSignal(0);
  const [searchQuery, setSearchQuery] = createSignal<string | undefined>(undefined);

  // Handler for Enter key - finds focused child and navigates
  function handleRowEnter(this: ElementNode) {
    const focused = this.children.find((c) => c.states?.has('focus')) as ElementNode | undefined;
    if (focused && focused.item?.href) {
      navigate(focused.item.href);
      return true;
    }
    return false;
  }

  // Fetch categories
  const [categories] = createResource(() => api.getCategories('movie'));

  // Fetch movies based on category and search
  const [movies] = createResource(
    () => ({
      category_id: selectedCategory(),
      offset: offset(),
      limit: ITEMS_PER_PAGE,
      search: searchQuery()
    }),
    (params) => api.getMovies(params)
  );

  // Handle search
  const handleSearch = (query: string) => {
    setSearchQuery(query);
    setSelectedCategory(undefined);
    setOffset(0);
  };

  // Chunk movies into rows
  const movieRows = () => {
    const data = movies()?.data || [];
    const rows: Movie[][] = [];
    for (let i = 0; i < data.length; i += ITEMS_PER_ROW) {
      rows.push(data.slice(i, i + ITEMS_PER_ROW));
    }
    return rows;
  };

  // Handle loading more
  const loadMore = () => {
    const total = movies()?.total || 0;
    const currentOffset = offset();
    if (currentOffset + ITEMS_PER_PAGE < total) {
      setOffset(currentOffset + ITEMS_PER_PAGE);
    }
  };

  return (
    <View width={1700} height={1080} forwardFocus={1}>
      {/* Header Background */}
      <View width={1700} height={160} color={0x0a0a0fff} zIndex={30} />

      {/* Header */}
      <View x={20} y={30} width={1660} height={60} zIndex={50}>
        <Text fontSize={42} fontWeight="bold" color={0xffffffff}>
          Filmes
        </Text>
      </View>

      {/* Category Filter */}
      <Row x={20} y={100} width={1660} height={50} gap={15} zIndex={40} autofocus>
        {/* Search */}
        <SearchBox onSearch={handleSearch} placeholder="Buscar filmes..." />
        {/* All button */}
        <CategoryButton
          label="Todos"
          selected={selectedCategory() === undefined && !searchQuery()}
          onSelect={() => {
            setSelectedCategory(undefined);
            setSearchQuery(undefined);
            setOffset(0);
          }}
        />
        <For each={categories()}>
          {(category: Category) => (
            <CategoryButton
              label={category.name}
              selected={selectedCategory() === category.id && !searchQuery()}
              onSelect={() => {
                setSelectedCategory(category.id);
                setSearchQuery(undefined);
                setOffset(0);
              }}
            />
          )}
        </For>
      </Row>

      {/* Movies Grid */}
      <Column x={20} y={170} width={1660} height={880} gap={30} scroll="always" forwardFocus={0}>
        <Show when={movies.loading}>
          <View width={1700} height={400} display="flex" justifyContent="center" alignItems="center">
            <Text fontSize={28} color={0x888888ff}>Carregando...</Text>
          </View>
        </Show>

        <Show when={!movies.loading && movieRows().length === 0}>
          <View width={1700} height={400} display="flex" justifyContent="center" alignItems="center">
            <Text fontSize={28} color={0x888888ff}>Nenhum filme encontrado</Text>
          </View>
        </Show>

        <For each={movieRows()}>
          {(row) => (
            <Row width={1640} height={440} gap={20} onEnter={handleRowEnter}>
              <For each={row}>
                {(movie: Movie) => (
                  <Card
                    title={movie.title}
                    imageUrl={movie.poster_url}
                    subtitle={movie.year?.toString()}
                    onFocus={() => api.prefetchMovie(movie.id)}
                    item={{ id: movie.id, type: 'movie', href: `/movie/${movie.id}` }}
                  />
                )}
              </For>
            </Row>
          )}
        </For>

        {/* Load More */}
        <Show when={movies()?.data && movies()!.data.length < (movies()?.total || 0)}>
          <View
            width={200}
            height={50}
            color={0x333333ff}
            borderRadius={8}
            display="flex"
            justifyContent="center"
            alignItems="center"
            onEnter={loadMore}
          >
            <Text fontSize={20} color={0xffffffff}>Carregar Mais</Text>
          </View>
        </Show>
      </Column>
    </View>
  );
};

interface CategoryButtonProps {
  label: string;
  selected: boolean;
  onSelect: () => void;
}

const CategoryButton = (props: CategoryButtonProps) => {
  const [focused, setFocused] = createSignal(false);

  return (
    <View
      width={Math.max(100, props.label.length * 14 + 32)}
      height={40}
      color={focused() ? 0xe50914ff : props.selected ? 0x444444ff : 0x222222ff}
      borderRadius={20}
      display="flex"
      justifyContent="center"
      alignItems="center"
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      onEnter={props.onSelect}
    >
      <Text
        fontSize={18}
        color={0xccccccff}
        fontWeight={props.selected ? 'bold' : 'normal'}
      >
        {props.label}
      </Text>
    </View>
  );
};

export default Movies;
