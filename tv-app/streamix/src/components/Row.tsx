import { View, Text, type NodeProps, ElementNode, activeElement } from '@lightningtv/solid';
import { Row as LightningRow } from '@lightningtv/solid/primitives';
import { For, Show, children as resolveChildren, type JSX } from 'solid-js';

export interface ContentRowProps extends NodeProps {
  title?: string;
  children: JSX.Element;
  onSelectedChanged?: (selected: number) => void;
  onItemSelected?: (item: any) => void;
  autofocus?: boolean;
}

const ContentRow = (props: ContentRowProps) => {
  const resolved = resolveChildren(() => props.children);

  // Handler for Enter key - finds focused child and triggers callback
  function handleEnter(this: ElementNode) {
    const focused = this.children.find((c) => c.states?.has('focus')) as ElementNode | undefined;
    if (focused && focused.item) {
      props.onItemSelected?.(focused.item);
      return true;
    }
    return false;
  }

  return (
    <View
      {...props}
      width={1700}
      height={props.title ? 520 : 460}
      // Forward focus to the LightningRow (child 1 if title exists, child 0 if not)
      forwardFocus={props.title ? 1 : 0}
    >
      <Show when={props.title}>
        <Text
          x={20}
          fontSize={32}
          fontWeight="bold"
          color={0xffffffff}
          y={0}
          zIndex={10}
        >
          {props.title}
        </Text>
      </Show>

      <LightningRow
        x={20}
        y={props.title ? 50 : 0}
        width={1660}
        height={460}
        gap={24}
        scroll="always"
        plinko
        autofocus={props.autofocus}
        onEnter={handleEnter}
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
