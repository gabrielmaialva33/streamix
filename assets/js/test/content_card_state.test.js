import assert from "node:assert/strict";
import test from "node:test";

import { favoriteActionLabel, updateFavoritePreviewButton } from "../hooks/content_card_state.js";

test("keeps the favorite preview icon and accessible action synchronized", () => {
  const attributes = new Map();
  const button = {
    innerHTML: "",
    setAttribute(name, value) {
      attributes.set(name, value);
    },
  };

  updateFavoritePreviewButton(button, {
    isFavorite: true,
    iconHtml: "<svg>filled</svg>",
  });

  assert.equal(button.innerHTML, "<svg>filled</svg>");
  assert.equal(attributes.get("aria-label"), "Remover dos favoritos");

  updateFavoritePreviewButton(button, {
    isFavorite: false,
    iconHtml: "<svg>outline</svg>",
  });

  assert.equal(button.innerHTML, "<svg>outline</svg>");
  assert.equal(attributes.get("aria-label"), "Adicionar aos favoritos");
  assert.equal(favoriteActionLabel(true), "Remover dos favoritos");
});
