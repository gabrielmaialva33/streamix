import { View, Text } from '@lightningtv/solid';
import { createSignal, onMount, onCleanup } from 'solid-js';

interface SearchBoxProps {
  onSearch: (query: string) => void;
  placeholder?: string;
}

/**
 * Search box that triggers native TV keyboard on focus.
 */
const SearchBox = (props: SearchBoxProps) => {
  const [focused, setFocused] = createSignal(false);
  const [query, setQuery] = createSignal('');
  let inputRef: HTMLInputElement | null = null;

  onMount(() => {
    // Create hidden HTML input for native keyboard
    inputRef = document.createElement('input');
    inputRef.type = 'text';
    inputRef.style.cssText = `
      position: fixed;
      top: -100px;
      left: -100px;
      width: 1px;
      height: 1px;
      opacity: 0;
    `;
    inputRef.placeholder = props.placeholder || 'Buscar...';

    inputRef.addEventListener('input', (e) => {
      const value = (e.target as HTMLInputElement).value;
      setQuery(value);
    });

    inputRef.addEventListener('change', (e) => {
      const value = (e.target as HTMLInputElement).value;
      if (value.trim().length >= 2) {
        props.onSearch(value.trim());
      }
    });

    // Handle keyboard done/enter (including Tizen keycodes)
    inputRef.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.keyCode === 13 || e.keyCode === 65376) {
        const value = (e.target as HTMLInputElement).value;
        if (value.trim().length >= 2) {
          props.onSearch(value.trim());
        }
        inputRef?.blur();
      }
      if (e.keyCode === 65385) { // Tizen cancel
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
    // Small delay to ensure Lightning has processed focus
    setTimeout(() => inputRef?.focus(), 50);
  };

  const handleBlur = () => {
    setFocused(false);
  };

  return (
    <View
      width={120}
      height={40}
      color={focused() ? 0xe50914ff : 0x333333ff}
      borderRadius={20}
      display="flex"
      justifyContent="center"
      alignItems="center"
      onFocus={handleFocus}
      onBlur={handleBlur}
      onEnter={() => inputRef?.focus()}
    >
      <Text fontSize={18} color={0xffffffff}>
        Buscar
      </Text>
    </View>
  );
};

export default SearchBox;
