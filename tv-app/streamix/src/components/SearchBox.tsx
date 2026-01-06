import { View, Text, type IntrinsicNodeStyleProps } from '@lightningtv/solid';
import { createSignal, onMount, onCleanup, Show } from 'solid-js';
import { theme } from '../styles';

const SearchBoxStyle = {
  width: 140,
  height: 40,
  color: 0x333333ff,
  borderRadius: 20,
  display: 'flex',
  justifyContent: 'center',
  alignItems: 'center',
  transition: {
    color: { duration: 150 },
    scale: { duration: 150 },
  },
  $focus: {
    color: theme.primary,
    scale: 1.05,
  },
} satisfies IntrinsicNodeStyleProps;

interface SearchBoxProps {
  onSearch: (query: string) => void;
  placeholder?: string;
  x?: number;
  y?: number;
}

/**
 * Search box that triggers native TV keyboard on focus.
 * On Samsung TV, we rely on blur event since keydown may not fire.
 */
const SearchBox = (props: SearchBoxProps) => {
  const [focused, setFocused] = createSignal(false);
  const [query, setQuery] = createSignal('');
  const [isSearching, setIsSearching] = createSignal(false);
  let inputRef: HTMLInputElement | null = null;

  onMount(() => {
    // Create hidden HTML input for native keyboard
    inputRef = document.createElement('input');
    inputRef.type = 'text';
    inputRef.enterKeyHint = 'search';
    inputRef.style.cssText = `
      position: fixed;
      top: 50%;
      left: 50%;
      width: 300px;
      height: 50px;
      opacity: 0.01;
      z-index: 9999;
      font-size: 24px;
    `;
    inputRef.placeholder = props.placeholder || 'Buscar...';

    // Track input changes
    inputRef.addEventListener('input', (e) => {
      const value = (e.target as HTMLInputElement).value;
      setQuery(value);
      console.log('[SearchBox] input:', value);
    });

    // Samsung TV keyboard closes and fires blur - this is our main trigger
    inputRef.addEventListener('blur', () => {
      console.log('[SearchBox] blur, query:', inputRef?.value);
      const value = inputRef?.value?.trim() || '';
      if (value.length >= 2) {
        console.log('[SearchBox] triggering search for:', value);
        props.onSearch(value);
        setIsSearching(true);
        setTimeout(() => setIsSearching(false), 2000);
      }
      // Reset input for next search
      if (inputRef) inputRef.value = '';
      setQuery('');
    });

    // Also handle Enter key for non-TV environments
    inputRef.addEventListener('keydown', (e) => {
      console.log('[SearchBox] keydown:', e.key, e.keyCode);
      if (e.key === 'Enter' || e.keyCode === 13 || e.keyCode === 65376) {
        e.preventDefault();
        inputRef?.blur();
      }
      if (e.keyCode === 65385) { // Tizen cancel
        if (inputRef) inputRef.value = '';
        inputRef?.blur();
      }
    });

    document.body.appendChild(inputRef);
  });

  onCleanup(() => {
    if (inputRef && inputRef.parentNode) {
      inputRef.parentNode.removeChild(inputRef);
    }
  });

  const handleFocus = () => {
    setFocused(true);
  };

  const handleBlur = () => {
    setFocused(false);
  };

  const openKeyboard = () => {
    console.log('[SearchBox] opening keyboard');
    // Small delay to ensure Lightning has processed focus
    setTimeout(() => {
      if (inputRef) {
        inputRef.value = '';
        inputRef.focus();
        inputRef.click(); // Some TVs need click to open keyboard
      }
    }, 100);
  };

  return (
    <View
      x={props.x}
      y={props.y}
      style={SearchBoxStyle}
      onFocus={handleFocus}
      onBlur={handleBlur}
      onEnter={openKeyboard}
      forwardStates
    >
      <Show when={!isSearching()} fallback={
        <Text fontSize={16} color={0xffffffff}>Buscando...</Text>
      }>
        <Text fontSize={16} color={0xffffffff}>
          {query() || 'Buscar'}
        </Text>
      </Show>
    </View>
  );
};

export default SearchBox;
