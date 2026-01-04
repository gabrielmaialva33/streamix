import { View, Text, type NodeProps } from '@lightningtv/solid';
import { Row as LightningRow } from '@lightningtv/solid/primitives';
import { For, Show, children as resolveChildren, type JSX } from 'solid-js';

export interface ContentRowProps extends NodeProps {
  title?: string;
  children: JSX.Element;
  onSelectedChanged?: (selected: number) => void;
}

const ContentRow = (props: ContentRowProps) => {
  const resolved = resolveChildren(() => props.children);

  return (
    <View
      {...props}
      width={1840}
      height={props.title ? 500 : 440}
    >
      <Show when={props.title}>
        <Text
          fontSize={32}
          fontWeight="bold"
          color={0xffffffff}
          y={0}
        >
          {props.title}
        </Text>
      </Show>

      <LightningRow
        y={props.title ? 50 : 0}
        width={1840}
        height={440}
        gap={20}
        scroll="always"
        plinko
        onSelectedChanged={(_, elm, index) => {
          props.onSelectedChanged?.(index);
        }}
      >
        {resolved()}
      </LightningRow>
    </View>
  );
};

export default ContentRow;
