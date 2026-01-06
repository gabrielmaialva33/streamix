import { View, Text, ElementNode, type IntrinsicNodeStyleProps } from '@lightningtv/solid';
import { Column, Row } from '@lightningtv/solid/primitives';
import { createSignal, createResource, createEffect, For, Show } from 'solid-js';
import { useNavigate } from '@solidjs/router';
import { Card, SearchBox, SkeletonLoader, ScrollIndicator } from '../components';
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
  const [accumulatedSeries, setAccumulatedSeries] = createSignal<SeriesType[]>([]);
  const [totalItems, setTotalItems] = createSignal(0);
  const [scrollPosition, setScrollPosition] = createSignal(0);

  let titleRow: ElementNode | undefined;
  let categoriesRow: ElementNode | undefined;
  let contentGrid: ElementNode | undefined;
  let loadMoreButton: ElementNode | undefined;

  // Fetch categories
  const [categories] = createResource(() => api.getCategories('series'));

  // Fetch series based on category and search
  const [seriesResource] = createResource(
    () => ({
      category_id: selectedCategory(),
      offset: offset(),
      limit: ITEMS_PER_PAGE,
      search: searchQuery()
    }),
    (params) => api.getSeries(params)
  );

  // Accumulate results when resource updates
  createEffect(() => {
    const result = seriesResource();
    if (result) {
      setTotalItems(result.total);
      if (offset() === 0) {
        // Fresh load (category change, search, etc) - replace data
        setAccumulatedSeries(result.data);
      } else {
        // Load more - append data and restore focus
        setAccumulatedSeries(prev => [...prev, ...result.data]);

        // Restore focus to load more button
        setTimeout(() => {
          if (loadMoreButton) {
            loadMoreButton.setFocus();
          }
        }, 100);
      }
    }
  });

  // Handle search
  const handleSearch = (query: string) => {
    setAccumulatedSeries([]);
    setSearchQuery(query);
    setSelectedCategory(undefined);
    setOffset(0);
  };

  // Chunk series into rows
  const seriesRows = () => {
    const data = accumulatedSeries();
    const rows: SeriesType[][] = [];
    for (let i = 0; i < data.length; i += ITEMS_PER_ROW) {
      rows.push(data.slice(i, i + ITEMS_PER_ROW));
    }
    return rows;
  };

  // Handle loading more
  const loadMore = () => {
    const total = totalItems();
    const currentCount = accumulatedSeries().length;
    if (currentCount < total) {
      setOffset(currentCount);
    }
  };

  // Navigate to series on Enter
  const handleSeriesSelect = (show: SeriesType) => {
    navigate(`/series/${show.id}`);
  };

  return (
    <View width={1700} height={1080}>
      {/* Fixed Header - solid background hides content scrolling behind */}
      <View x={0} y={0} width={1700} height={140} zIndex={10} color={0x0a0a0fff}>
        {/* Title and Search */}
        <Row
          ref={titleRow}
          width={1660}
          height={70}
          x={20}
          gap={20}
          scroll="none"
          onDown={() => categoriesRow?.setFocus()}
        >
          <View width={1400} skipFocus>
            <Text y={15} fontSize={42} fontWeight="bold" color={0xffffffff}>
              Séries
            </Text>
          </View>
          <SearchBox onSearch={handleSearch} placeholder="Buscar séries..." />
        </Row>

        {/* Category Filter - horizontal scrolling */}
        <Row
          ref={categoriesRow}
          x={20}
          y={70}
          width={1660}
          height={50}
          gap={12}
          scroll="auto"
          autofocus
          onUp={() => titleRow?.setFocus()}
          onDown={() => contentGrid?.setFocus()}
        >
          <View
            width={100}
            style={selectedCategory() === undefined && !searchQuery() ? SelectedCategoryStyle : CategoryButtonStyle}
            onEnter={() => {
              setAccumulatedSeries([]);
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
                  setAccumulatedSeries([]);
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
      </View>

      {/* Series Grid - below fixed header with clipping */}
      <Column
        ref={contentGrid}
        x={20}
        y={140}
        width={1640}
        height={930}
        gap={24}
        scroll="auto"
        plinko
        clipping
        onUp={() => categoriesRow?.setFocus()}
        onScrolled={(ref, pos, isInitial) => {
          if (!isInitial && ref.children.length > 0) {
            const totalContentHeight = ref.children.length * (420 + 24);
            const viewportHeight = 930;
            const maxScroll = Math.max(1, totalContentHeight - viewportHeight);
            setScrollPosition(Math.abs(pos) / maxScroll);
          }
        }}
      >
        <Show when={seriesResource.loading && accumulatedSeries().length === 0}>
          {/* Skeleton loaders */}
          <Row width={1640} height={420} gap={16} scroll="none" skipFocus>
            <For each={[1, 2, 3, 4, 5, 6]}>
              {() => (
                <View width={240} height={420}>
                  <SkeletonLoader width={240} height={360} />
                  <SkeletonLoader width={180} height={20} y={370} borderRadius={4} />
                </View>
              )}
            </For>
          </Row>
        </Show>

        <Show when={!seriesResource.loading && seriesRows().length === 0}>
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
        <Show when={accumulatedSeries().length > 0 && accumulatedSeries().length < totalItems()}>
          <Row width={1640} height={60} justifyContent="center">
            <View
              ref={loadMoreButton}
              width={200}
              height={50}
              borderRadius={8}
              display="flex"
              justifyContent="center"
              alignItems="center"
              style={{
                color: 0x333333ff,
                transition: { scale: { duration: 150 } },
                $focus: { scale: 1.1, color: 0xe50914ff },
              }}
              onEnter={loadMore}
            >
              <Text fontSize={18} color={0xffffffff}>
                {seriesResource.loading ? 'Carregando...' : 'Carregar Mais'}
              </Text>
            </View>
          </Row>
        </Show>
      </Column>

      {/* Scroll Indicator */}
      <ScrollIndicator
        x={1680}
        y={160}
        scrollPosition={scrollPosition()}
        trackHeight={880}
        autoHideDelay={1500}
      />
    </View>
  );
};

export default Series;
