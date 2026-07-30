/**
 * The first controller claim turns a normal tab into a controlled PWA page.
 * That is not an update and must not reload the document. Every later
 * controller replacement is a real service-worker update.
 */
export function createControllerChangeGuard(initialController) {
  let currentController = initialController;

  return (nextController) => {
    const shouldReload = currentController !== null;
    currentController = nextController;
    return shouldReload;
  };
}
