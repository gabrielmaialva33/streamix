import { render as solidRender, Config } from "@lightningtv/solid";

Config.rendererOptions = {
  rootId: document.createElement("div"),
};

export function render(Component) {
  return solidRender(() => <Component />);
}
