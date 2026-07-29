export function pwaInstallMode({
  standalone = false,
  iosWebKit = false,
  hasNativePrompt = false,
} = {}) {
  if (standalone) return "installed";
  if (hasNativePrompt) return "native";
  if (iosWebKit) return "ios";
  return "unavailable";
}

export async function promptForPwaInstall(promptEvent) {
  if (typeof promptEvent?.prompt !== "function") {
    return { outcome: "unavailable", platform: null };
  }

  await promptEvent.prompt();
  const choice = await promptEvent.userChoice;

  return {
    outcome: choice?.outcome === "accepted" ? "accepted" : "dismissed",
    platform: choice?.platform || null,
  };
}
