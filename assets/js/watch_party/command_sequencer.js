/**
 * Orders room commands by the monotonic sequence the server stamps on them,
 * falling back to `server_time` for legacy payloads without a sequence.
 */
export class CommandSequencer {
  constructor() {
    this.lastSequence = 0;
    this.lastServerTime = 0;
  }

  accept(command, { holding = false } = {}) {
    const sequence = Number(command?.sequence);
    if (Number.isInteger(sequence) && sequence > 0) {
      if (sequence < this.lastSequence) return false;
      if (sequence === this.lastSequence) {
        // A repeated snapshot may only re-apply while the viewer is held.
        return holding && command?.type === "sync";
      }
      this.lastSequence = sequence;
      return true;
    }

    const serverTime = Number(command?.server_time);
    if (Number.isFinite(serverTime)) {
      if (serverTime <= this.lastServerTime) return false;
      this.lastServerTime = serverTime;
    }

    return true;
  }

  snapshot() {
    return Object.freeze({
      lastSequence: this.lastSequence,
      lastServerTime: this.lastServerTime,
    });
  }
}

export function createCommandSequencer() {
  return new CommandSequencer();
}
