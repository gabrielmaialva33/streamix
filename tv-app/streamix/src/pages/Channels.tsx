import { View, Text } from '@lightningtv/solid';
import { Column, Row } from '@lightningtv/solid/primitives';
import { createSignal, createResource, For, Show } from 'solid-js';
import { useNavigate } from '@solidjs/router';
import api, { type Channel } from '../lib/api';

const ITEMS_PER_ROW = 8;

const Channels = () => {
  const navigate = useNavigate();
  const [selectedGroup, setSelectedGroup] = createSignal<string | undefined>(undefined);

  // Fetch channels
  const [channels] = createResource(
    () => ({ group: selectedGroup(), limit: 100 }),
    (params) => api.getChannels(params)
  );

  // Get unique groups
  const groups = () => {
    const data = channels()?.data || [];
    const uniqueGroups = new Set(data.map(c => c.group).filter(Boolean));
    return Array.from(uniqueGroups) as string[];
  };

  // Chunk channels into rows
  const channelRows = () => {
    const data = channels()?.data || [];
    const rows: Channel[][] = [];
    for (let i = 0; i < data.length; i += ITEMS_PER_ROW) {
      rows.push(data.slice(i, i + ITEMS_PER_ROW));
    }
    return rows;
  };

  return (
    <View x={220} width={1700} height={1080}>
      {/* Header */}
      <View y={30} width={1700} height={60}>
        <Text fontSize={42} fontWeight="bold" color={0xffffffff}>
          Live Channels
        </Text>
      </View>

      {/* Group Filter */}
      <Row y={100} width={1700} height={50} gap={15}>
        <GroupButton
          label="All"
          selected={selectedGroup() === undefined}
          onSelect={() => setSelectedGroup(undefined)}
        />
        <For each={groups()}>
          {(group) => (
            <GroupButton
              label={group}
              selected={selectedGroup() === group}
              onSelect={() => setSelectedGroup(group)}
            />
          )}
        </For>
      </Row>

      {/* Channels Grid */}
      <Column y={170} width={1700} height={880} gap={20} scroll="always">
        <Show when={channels.loading}>
          <View width={1700} height={400} display="flex" justifyContent="center" alignItems="center">
            <Text fontSize={28} color={0x888888ff}>Loading...</Text>
          </View>
        </Show>

        <Show when={!channels.loading && channelRows().length === 0}>
          <View width={1700} height={400} display="flex" justifyContent="center" alignItems="center">
            <Text fontSize={28} color={0x888888ff}>No channels found</Text>
          </View>
        </Show>

        <For each={channelRows()}>
          {(row) => (
            <Row width={1700} height={160} gap={15}>
              <For each={row}>
                {(channel: Channel) => (
                  <ChannelCard
                    channel={channel}
                    onSelect={() => navigate(`/player/channel/${channel.id}`)}
                  />
                )}
              </For>
            </Row>
          )}
        </For>
      </Column>
    </View>
  );
};

interface ChannelCardProps {
  channel: Channel;
  onSelect: () => void;
}

const ChannelCard = (props: ChannelCardProps) => {
  const [focused, setFocused] = createSignal(false);

  return (
    <View
      width={200}
      height={140}
      color={focused() ? 0x2a2a3eff : 0x1a1a2eff}
      borderRadius={12}
      scale={focused() ? 1.05 : 1}
      transition={{ scale: { duration: 150 } }}
      effects={focused() ? [{
        type: 'border',
        props: { color: 0xe50914ff, width: 3 }
      }] : undefined}
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      onEnter={props.onSelect}
    >
      {/* Logo */}
      <Show when={props.channel.logo_url}>
        <View
          x={50}
          y={20}
          width={100}
          height={70}
          src={props.channel.logo_url}
        />
      </Show>
      <Show when={!props.channel.logo_url}>
        <View
          x={50}
          y={15}
          width={100}
          height={70}
          color={0x333333ff}
          borderRadius={8}
        />
      </Show>

      {/* Name */}
      <Text
        x={10}
        y={100}
        width={180}
        height={30}
        fontSize={16}
        color={focused() ? 0xffffffff : 0xccccccff}
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

interface GroupButtonProps {
  label: string;
  selected: boolean;
  onSelect: () => void;
}

const GroupButton = (props: GroupButtonProps) => {
  const [focused, setFocused] = createSignal(false);

  return (
    <View
      width={Math.max(80, props.label.length * 12 + 24)}
      height={36}
      color={focused() ? 0xe50914ff : props.selected ? 0x444444ff : 0x222222ff}
      borderRadius={18}
      display="flex"
      justifyContent="center"
      alignItems="center"
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      onEnter={props.onSelect}
    >
      <Text
        fontSize={16}
        color={focused() || props.selected ? 0xffffffff : 0xaaaaaaff}
        fontWeight={props.selected ? 'bold' : 'normal'}
      >
        {props.label}
      </Text>
    </View>
  );
};

export default Channels;
