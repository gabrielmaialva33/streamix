import { View, Text, ElementNode, type IntrinsicNodeStyleProps } from '@lightningtv/solid';
import { Column, Row } from '@lightningtv/solid/primitives';
import { createSignal, createResource, For, Show } from 'solid-js';
import { useNavigate } from '@solidjs/router';
import { Card, SearchBox } from '../components';
import api, { type Series as SeriesType, type Category } from '../lib/api';

const ITEMS_PER_ROW = 6;
const ITEMS_PER_PAGE = 30;

// Style constants following demo app patterns
const CategoryButtonStyle = {
  height: 40,
  borderRadius: 20,
  display: 'flex',
  justifyContent: 'center',
  alignItems: 'center',
  color: 0x222222ff,
  scale: 1,
  transition: {
    color: { duration: 150, easing: 'ease-out' },
    scale: { duration: 150, easing: 'ease-out' },
  },
  $focus: {
    color: 0xe50914ff,
    scale: 1.1,
  },
} satisfies IntrinsicNodeStyleProps;

const SelectedCategoryStyle = {
  ...CategoryButtonStyle,
  color: 0x444444ff,
} satisfies IntrinsicNodeStyleProps;

const Series = () => {
  const navigate = useNavigate();
  const [selectedCategory, setSelectedCategory] = createSignal<string | undefined>(undefined);
  const [offset, setOffset] = createSignal(0);
  const [searchQuery, setSearchQuery] = createSignal<string | undefined>(undefined);

  let categoriesRow: ElementNode | undefined;
  let contentGrid: ElementNode | undefined;

  // Fetch categories
  const [categories] = createResource(() => api.getCategories('series'));

  // Fetch series based on category and search
  const [series] = createResource(
    () => ({
      category_id: selectedCategory(),
      offset: offset(),
      limit: ITEMS_PER_PAGE,
      search: searchQuery()
    }),
    (params) => api.getSeries(params)
  );

  // Handle search
  const handleSearch = (query: string) => {
    setSearchQuery(query);
    setSelectedCategory(undefined);
    setOffset(0);
  };

  // Chunk series into rows
  const seriesRows = () => {
    const data = series()?.data || [];
    const rows: SeriesType[][] = [];
    for (let i = 0; i < data.length; i += ITEMS_PER_ROW) {
      rows.push(data.slice(i, i + ITEMS_PER_ROW));
    }
    return rows;
  };

  // Handle loading more
  const loadMore = () => {
    const total = series()?.total || 0;
    const currentOffset = offset();
    if (currentOffset + ITEMS_PER_PAGE < total) {
      setOffset(currentOffset + ITEMS_PER_PAGE);
    }
  };

  // Navigate to series on Enter
  const handleSeriesSelect = (show: SeriesType) => {
    navigate(`/series/${show.id}`);
  };

  return (
    <Column
      width={1700}
      height={1080}
      y={0}
      scroll="none"
    >
      {/* Header - not focusable */}
      <View width={1660} height={70} x={20} skipFocus>
        <Text y={15} fontSize={42} fontWeight="bold" color={0xffffffff}>
          Series
        </Text>
        <View x={1500} y={15}>
          <SearchBox onSearch={handleSearch} placeholder="Buscar series..." />
        </View>
      </View>

      {/* Category Filter - horizontal scrolling */}
      <Row
        ref={categoriesRow}
        x={20}
        width={1660}
        height={50}
        gap={12}
        scroll="auto"
        autofocus
        onDown={() => contentGrid?.setFocus()}
      >
        <View
          width={100}
          style={selectedCategory() === undefined && !searchQuery() ? SelectedCategoryStyle : CategoryButtonStyle}
          onEnter={() => {
            setSelectedCategory(undefined);
            setSearchQuery(undefined);
            setOffset(0);
          }}
        >
          <Text fontSize={16} color={0xffffffff}>Todas</Text>
        </View>
        <For each={categories()}>
          {(category: Category) => (
            <View
              width={Math.max(100, category.name.length * 10 + 24)}
              style={selectedCategory() === category.id && !searchQuery() ? SelectedCategoryStyle : CategoryButtonStyle}
              onEnter={() => {
                setSelectedCategory(category.id);
                setSearchQuery(undefined);
                setOffset(0);
              }}
            >
              <Text fontSize={16} color={0xffffffff}>{category.name}</Text>
            </View>
          )}
        </For>
      </Row>

      {/* Series Grid - vertical scrolling */}
      <Column
        ref={contentGrid}
        x={20}
        y={10}
        width={1660}
        height={900}
        gap={24}
        scroll="auto"
        plinko
        onUp={() => categoriesRow?.setFocus()}
      >
        <Show when={series.loading}>
          <View width={1640} height={400} display="flex" justifyContent="center" alignItems="center" skipFocus>
            <Text fontSize={28} color={0x888888ff}>Carregando...</Text>
          </View>
        </Show>

        <Show when={!series.loading && seriesRows().length === 0}>
          <View width={1640} height={400} display="flex" justifyContent="center" alignItems="center" skipFocus>
            <Text fontSize={28} color={0x888888ff}>Nenhuma série encontrada</Text>
          </View>
        </Show>

        <For each={seriesRows()}>
          {(row) => (
            <Row width={1640} height={420} gap={16} scroll="none">
              <For each={row}>
                {(show: SeriesType) => (
                  <Card
                    title={show.title}
                    imageUrl={show.poster_url}
                    subtitle={show.year?.toString()}
                    onFocus={() => api.prefetchSeries(String(show.id))}
                    onEnter={() => handleSeriesSelect(show)}
                    item={{ id: show.id, type: 'series', href: `/series/${show.id}` }}
                  />
                )}
              </For>
            </Row>
          )}
        </For>

        {/* Load More Button */}
        <Show when={series()?.data && series()!.data.length < (series()?.total || 0)}>
          <Row width={1640} height={60} justifyContent="center">
            <View
              width={200}
              height={50}
              color={0x333333ff}
              borderRadius={8}
              display="flex"
              justifyContent="center"
              alignItems="center"
              style={{
                transition: { scale: { duration: 150 } },
                $focus: { scale: 1.1, color: 0xe50914ff },
              }}
              onEnter={loadMore}
            >
              <Text fontSize={18} color={0xffffffff}>Carregar Mais</Text>
            </View>
          </Row>
        </Show>
      </Column>
    </Column>
  );
};

export default Series;
