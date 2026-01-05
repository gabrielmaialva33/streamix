import { View, Text } from '@lightningtv/solid';
import { Column, Row } from '@lightningtv/solid/primitives';
import { createSignal, createResource, For, Show } from 'solid-js';
import { useNavigate } from '@solidjs/router';
import { Card } from '../components';
import api, { type Movie, type Series, type Channel } from '../lib/api';

const KEYBOARD_ROWS = [
  ['A', 'B', 'C', 'D', 'E', 'F', 'G'],
  ['H', 'I', 'J', 'K', 'L', 'M', 'N'],
  ['O', 'P', 'Q', 'R', 'S', 'T', 'U'],
  ['V', 'W', 'X', 'Y', 'Z', '0', '1'],
  ['2', '3', '4', '5', '6', '7', '8'],
  ['9', ' ', 'DEL', 'OK'],
];

const Search = () => {
  const navigate = useNavigate();
  const [query, setQuery] = createSignal('');
  const [searchTriggered, setSearchTriggered] = createSignal(false);

  // Search results
  const [results] = createResource(
    () => searchTriggered() ? query() : null,
    async (q) => {
      if (!q || q.trim().length < 2) return null;
      return await api.search(q.trim());
    }
  );

  const handleKey = (key: string) => {
    if (key === 'DEL') {
      setQuery(q => q.slice(0, -1));
    } else if (key === 'OK') {
      if (query().trim().length >= 2) {
        setSearchTriggered(true);
      }
    } else if (key === ' ') {
      setQuery(q => q + ' ');
    } else {
      setQuery(q => q + key);
      setSearchTriggered(false);
    }
  };

  const totalResults = () => {
    const r = results();
    if (!r) return 0;
    return (r.movies?.length || 0) + (r.series?.length || 0) + (r.channels?.length || 0);
  };

  return (
    <View width={1700} height={1080} forwardFocus={2}>
      {/* Header */}
      <View y={30} width={1700} height={60}>
        <Text fontSize={42} fontWeight="bold" color={0xffffffff}>
          Buscar
        </Text>
      </View>

      {/* Search Input Display */}
      <View y={100} width={600} height={60} color={0x1a1a2eff} borderRadius={8}>
        <Text x={20} y={15} fontSize={28} color={query() ? 0xffffffff : 0x666666ff}>
          {query() || 'Digite para buscar...'}
        </Text>
        <View x={query().length * 16 + 20} y={10} width={3} height={40} color={0xe50914ff} />
      </View>

      {/* Keyboard */}
      <Column y={180} width={500} height={300} gap={10} autofocus forwardFocus={0}>
        <For each={KEYBOARD_ROWS}>
          {(row) => (
            <Row width={500} height={45} gap={8}>
              <For each={row}>
                {(key) => (
                  <KeyboardKey
                    key={key}
                    onPress={() => handleKey(key)}
                  />
                )}
              </For>
            </Row>
          )}
        </For>
      </Column>

      {/* Results */}
      <View x={550} y={100} width={1150} height={950}>
        <Show when={results.loading}>
          <View width={1150} height={400} display="flex" justifyContent="center" alignItems="center">
            <Text fontSize={28} color={0x888888ff}>Buscando...</Text>
          </View>
        </Show>

        <Show when={searchTriggered() && !results.loading && totalResults() === 0}>
          <View width={1150} height={400} display="flex" justifyContent="center" alignItems="center">
            <Text fontSize={28} color={0x888888ff}>Nenhum resultado encontrado</Text>
          </View>
        </Show>

        <Column width={1150} height={950} gap={30} scroll="always">
          {/* Movies */}
          <Show when={results()?.movies?.length}>
            <View width={1150} height={450}>
              <Text fontSize={24} color={0xffffffff} fontWeight="bold">
                Filmes ({results()!.movies.length})
              </Text>
              <Row y={40} width={1150} height={400} gap={15}>
                <For each={results()!.movies.slice(0, 4)}>
                  {(movie: Movie) => (
                    <Card
                      title={movie.title}
                      imageUrl={movie.poster_url}
                      subtitle={movie.year?.toString()}
                      width={200}
                      height={300}
                      onEnter={() => navigate(`/movie/${movie.id}`)}
                    />
                  )}
                </For>
              </Row>
            </View>
          </Show>

          {/* Series */}
          <Show when={results()?.series?.length}>
            <View width={1150} height={450}>
              <Text fontSize={24} color={0xffffffff} fontWeight="bold">
                Séries ({results()!.series.length})
              </Text>
              <Row y={40} width={1150} height={400} gap={15}>
                <For each={results()!.series.slice(0, 4)}>
                  {(show: Series) => (
                    <Card
                      title={show.title}
                      imageUrl={show.poster_url}
                      subtitle={show.year?.toString()}
                      width={200}
                      height={300}
                      onEnter={() => navigate(`/series/${show.id}`)}
                    />
                  )}
                </For>
              </Row>
            </View>
          </Show>

          {/* Channels */}
          <Show when={results()?.channels?.length}>
            <View width={1150} height={200}>
              <Text fontSize={24} color={0xffffffff} fontWeight="bold">
                Canais ({results()!.channels.length})
              </Text>
              <Row y={40} width={1150} height={140} gap={15}>
                <For each={results()!.channels.slice(0, 6)}>
                  {(channel: Channel) => (
                    <ChannelResult
                      channel={channel}
                      onSelect={() => navigate(`/player/channel/${channel.id}`)}
                    />
                  )}
                </For>
              </Row>
            </View>
          </Show>
        </Column>
      </View>
    </View>
  );
};

interface KeyboardKeyProps {
  key: string;
  onPress: () => void;
}

const KeyboardKey = (props: KeyboardKeyProps) => {
  const [focused, setFocused] = createSignal(false);

  const isSpecial = props.key === 'DEL' || props.key === 'OK' || props.key === ' ';
  const width = isSpecial ? 90 : 60;

  return (
    <View
      width={width}
      height={45}
      color={focused() ? 0xe50914ff : 0x333333ff}
      borderRadius={6}
      display="flex"
      justifyContent="center"
      alignItems="center"
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      onEnter={props.onPress}
    >
      <Text fontSize={20} color={focused() ? 0xffffffff : 0xccccccff}>
        {props.key === ' ' ? 'SPC' : props.key}
      </Text>
    </View>
  );
};

interface ChannelResultProps {
  channel: Channel;
  onSelect: () => void;
}

const ChannelResult = (props: ChannelResultProps) => {
  const [focused, setFocused] = createSignal(false);

  return (
    <View
      width={170}
      height={120}
      color={focused() ? 0x333333ff : 0x222222ff}
      borderRadius={8}
      border={focused() ? { color: 0xe50914ff, width: 2 } : { color: 0x00000000, width: 0 }}
      transition={{ border: { duration: 150 } }}
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      onEnter={props.onSelect}
    >
      <Show when={props.channel.logo_url}>
        <View x={35} y={15} width={100} height={60} src={props.channel.logo_url} />
      </Show>
      <Text
        x={10}
        y={85}
        width={150}
        fontSize={14}
        color={0xccccccff}
        contain="both"
        textOverflow="ellipsis"
        textAlign="center"
        maxLines={1}
      >
        {props.channel.name}
      </Text>
    </View>
  );
};

export default Search;
