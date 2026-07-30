export function evaluateFallbackAttempt({ attempts, maxAttempts, lastAttemptAt, cooldowns }, now) {
  let effectiveAttempts = attempts;
  const elapsed = Math.max(0, now - lastAttemptAt);

  if (effectiveAttempts >= maxAttempts) {
    const maximumCooldown = cooldowns.at(-1);

    if (elapsed < maximumCooldown) {
      return {
        allowed: false,
        attempts: effectiveAttempts,
        remainingMs: maximumCooldown - elapsed,
        reason: "max_attempts",
      };
    }

    effectiveAttempts = 0;
  }

  if (effectiveAttempts > 0 && lastAttemptAt > 0) {
    const cooldownIndex = Math.min(effectiveAttempts - 1, cooldowns.length - 1);
    const requiredCooldown = cooldowns[cooldownIndex];

    if (elapsed < requiredCooldown) {
      return {
        allowed: false,
        attempts: effectiveAttempts,
        remainingMs: requiredCooldown - elapsed,
        reason: "cooldown",
      };
    }
  }

  return {
    allowed: true,
    attempts: effectiveAttempts,
    remainingMs: 0,
    reason: null,
  };
}
