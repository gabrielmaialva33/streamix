export function favoriteActionLabel(isFavorite) {
  return isFavorite ? "Remover dos favoritos" : "Adicionar aos favoritos";
}

export function updateFavoritePreviewButton(button, { isFavorite, iconHtml }) {
  if (!button) return;

  button.innerHTML = iconHtml;
  button.setAttribute("aria-label", favoriteActionLabel(isFavorite));
}
