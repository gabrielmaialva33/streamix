import { View, Text } from '@lightningtv/solid';
import { Column, Row } from '@lightningtv/solid/primitives';
import { createSignal, createResource, For, Show } from 'solid-js';
import { useNavigate } from '@solidjs/router';
import { Card } from '../components';
import api, { type Series as SeriesType, type Category } from '../lib/api';

const ITEMS_PER_ROW = 6;
const ITEMS_PER_PAGE = 30;

const Series = () => {
  const navigate = useNavigate();
  const [selectedCategory, setSelectedCategory] = createSignal<string | undefined>(undefined);
  const [offset, setOffset] = createSignal(0);

  // Fetch categories
  const [categories] = createResource(() => api.getCategories('series'));

  // Fetch series based on category
  const [series] = createResource(
    () => ({ category_id: selectedCategory(), offset: offset(), limit: ITEMS_PER_PAGE }),
    (params) => api.getSeries(params)
  );

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

  return (
    <View x={220} width={1700} height={1080}>
      {/* Header */}
      <View y={30} width={1700} height={60}>
        <Text fontSize={42} fontWeight="bold" color={0xffffffff}>
          TV Series
        </Text>
      </View>

      {/* Category Filter */}
      <Row y={100} width={1700} height={50} gap={15}>
        {/* All button */}
        <CategoryButton
          label="All"
          selected={selectedCategory() === undefined}
          onSelect={() => {
            setSelectedCategory(undefined);
            setOffset(0);
          }}
        />
        <For each={categories()}>
          {(category: Category) => (
            <CategoryButton
              label={category.name}
              selected={selectedCategory() === category.id}
              onSelect={() => {
                setSelectedCategory(category.id);
                setOffset(0);
              }}
            />
          )}
        </For>
      </Row>

      {/* Series Grid */}
      <Column y={170} width={1700} height={880} gap={30} scroll="always">
        <Show when={series.loading}>
          <View width={1700} height={400} display="flex" justifyContent="center" alignItems="center">
            <Text fontSize={28} color={0x888888ff}>Loading...</Text>
          </View>
        </Show>

        <Show when={!series.loading && seriesRows().length === 0}>
          <View width={1700} height={400} display="flex" justifyContent="center" alignItems="center">
            <Text fontSize={28} color={0x888888ff}>No series found</Text>
          </View>
        </Show>

        <For each={seriesRows()}>
          {(row) => (
            <Row width={1700} height={440} gap={20}>
              <For each={row}>
                {(show: SeriesType) => (
                  <Card
                    title={show.title}
                    imageUrl={show.poster_url}
                    subtitle={show.year?.toString()}
                    onFocus={() => api.prefetchSeries(show.id)}
                    onEnter={() => navigate(`/series/${show.id}`)}
                  />
                )}
              </For>
            </Row>
          )}
        </For>

        {/* Load More */}
        <Show when={series()?.data && series()!.data.length < (series()?.total || 0)}>
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
            <Text fontSize={20} color={0xffffffff}>Load More</Text>
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
        color={focused() || props.selected ? 0xffffffff : 0xaaaaaaff}
        fontWeight={props.selected ? 'bold' : 'normal'}
      >
        {props.label}
      </Text>
    </View>
  );
};

export default Series;
