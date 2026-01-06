import { View, type NodeProps, type IntrinsicNodeStyleProps, ElementNode } from '@lightningtv/solid';
import { createSignal, createEffect, onCleanup } from 'solid-js';
import { theme } from '../styles';

// Scroll indicator track (background)
const TrackStyle = {
  borderRadius: 3,
  color: theme.surfaceLight,
  alpha: 0.3,
} satisfies IntrinsicNodeStyleProps;

// Scroll indicator thumb
const ThumbStyle = {
  borderRadius: 3,
  color: theme.primary,
} satisfies IntrinsicNodeStyleProps;

export interface ScrollIndicatorProps extends NodeProps {
  /** Current scroll position (use with onScrolled callback) */
  scrollPosition?: number;
  /** Total content height */
  contentHeight?: number;
  /** Visible viewport height */
  viewportHeight?: number;
  /** Indicator track width */
  trackWidth?: number;
  /** Indicator track height */
  trackHeight?: number;
  /** Auto-hide delay in ms (0 to disable) */
  autoHideDelay?: number;
}

/**
 * ScrollIndicator - Shows scroll position for long lists
 *
 * Usage with Column/Row:
 * ```tsx
 * const [scrollPos, setScrollPos] = createSignal(0);
 *
 * <Column
 *   onScrolled={(ref, pos) => {
 *     const total = ref.children.reduce((sum, c) => sum + (c.height || 0), 0);
 *     setScrollPos(Math.abs(pos) / (total - ref.height));
 *   }}
 * >
 *   ...
 * </Column>
 * <ScrollIndicator
 *   scrollPosition={scrollPos()}
 *   x={1660}
 *   trackHeight={800}
 * />
 * ```
 */
const ScrollIndicator = (props: ScrollIndicatorProps) => {
  const trackWidth = props.trackWidth || 6;
  const trackHeight = props.trackHeight || 400;
  const autoHideDelay = props.autoHideDelay ?? 2000;

  const [visible, setVisible] = createSignal(false);
  let hideTimer: ReturnType<typeof setTimeout> | undefined;

  // Calculate thumb height and position
  const thumbHeight = () => {
    if (!props.contentHeight || !props.viewportHeight) {
      // If no explicit sizes, use scrollPosition as ratio (0-1)
      return Math.max(trackHeight * 0.15, 40); // Min thumb size
    }
    const ratio = props.viewportHeight / props.contentHeight;
    return Math.max(trackHeight * ratio, 40); // Min 40px
  };

  const thumbPosition = () => {
    const scrollRatio = Math.min(Math.max(props.scrollPosition || 0, 0), 1);
    const availableTrack = trackHeight - thumbHeight();
    return scrollRatio * availableTrack;
  };

  // Show indicator when scroll position changes
  createEffect(() => {
    const pos = props.scrollPosition;
    if (pos !== undefined) {
      setVisible(true);

      // Auto-hide after delay
      if (autoHideDelay > 0) {
        if (hideTimer) clearTimeout(hideTimer);
        hideTimer = setTimeout(() => setVisible(false), autoHideDelay);
      }
    }
  });

  // Cleanup timer on unmount
  onCleanup(() => {
    if (hideTimer) clearTimeout(hideTimer);
  });

  return (
    <View
      {...props}
      width={trackWidth}
      height={trackHeight}
      style={TrackStyle}
      alpha={visible() ? 0.8 : 0}
      transition={{ alpha: { duration: 200, easing: 'ease-out' } }}
      skipFocus
    >
      {/* Thumb */}
      <View
        y={thumbPosition()}
        width={trackWidth}
        height={thumbHeight()}
        style={ThumbStyle}
      />
    </View>
  );
};

export default ScrollIndicator;
