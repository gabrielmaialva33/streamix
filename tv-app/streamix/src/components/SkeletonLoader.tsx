import { View, type NodeProps, type IntrinsicNodeStyleProps } from '@lightningtv/solid';
import { createSignal, onMount, onCleanup } from 'solid-js';

export interface SkeletonLoaderProps extends NodeProps {
  width?: number;
  height?: number;
  borderRadius?: number;
}

/**
 * Skeleton Loader - Animated placeholder while content loads
 * Uses alpha pulse animation for visual feedback
 */
const SkeletonLoader = (props: SkeletonLoaderProps) => {
  const [alpha, setAlpha] = createSignal(0.3);
  let animationFrame: number;
  let startTime: number;

  onMount(() => {
    startTime = Date.now();

    const animate = () => {
      const elapsed = Date.now() - startTime;
      // Pulse between 0.2 and 0.5 alpha over 1.5 seconds
      const progress = (Math.sin(elapsed / 750) + 1) / 2;
      setAlpha(0.2 + progress * 0.3);
      animationFrame = requestAnimationFrame(animate);
    };

    animationFrame = requestAnimationFrame(animate);
  });

  onCleanup(() => {
    if (animationFrame) {
      cancelAnimationFrame(animationFrame);
    }
  });

  return (
    <View
      {...props}
      width={props.width || 240}
      height={props.height || 360}
      color={0x2a2a3eff}
      alpha={alpha()}
      borderRadius={props.borderRadius || 12}
    />
  );
};

export default SkeletonLoader;
