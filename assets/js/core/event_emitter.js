// Legacy wrapper contract: registration order, duplicates allowed, on/off return
// undefined. off removes all copies. Emission iterates the current array: an off
// replaces it for the next emission; on appends to it for the current emission.
// Listener failures are reported independently and never stop later listeners.
export function createEventEmitter({ events = new Map(), onError = () => {} } = {}) {
  return {
    on(event, handler) {
      const list = events.get(event) || [];
      list.push(handler);
      events.set(event, list);
    },
    off(event, handler) {
      const list = events.get(event);
      if (list)
        events.set(
          event,
          list.filter((entry) => entry !== handler),
        );
    },
    emit(event, ...args) {
      for (const handler of events.get(event) || []) {
        try {
          handler(...args);
        } catch (error) {
          onError(event, error);
        }
      }
    },
  };
}
