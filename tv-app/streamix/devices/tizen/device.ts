import { EDeviceType } from "@/managers/device";
import { DeviceCommon } from "#devices/common/device";
import { TizenPlayer } from "./player";

declare const tizen: any;

// Keys that need to be registered on Samsung Tizen TV
const TIZEN_KEYS_TO_REGISTER = [
  "Back",  // CRITICAL: Prevents app exit, allows in-app navigation
  "MediaPlay",
  "MediaPause",
  "MediaPlayPause",
  "MediaStop",
  "MediaFastForward",
  "MediaRewind",
  "MediaTrackPrevious",
  "MediaTrackNext",
  "ColorF0Red",
  "ColorF1Green",
  "ColorF2Yellow",
  "ColorF3Blue",
  "Exit",
];

export class TizenDevice extends DeviceCommon {
  static addScript(): Promise<boolean> {
    return new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = "$WEBAPIS/webapis/webapis.js";
      script.onload = () => resolve(true);
      script.onerror = () => reject(new Error("Failed load device Script $WEBAPIS/webapis/webapis.js"));
      document.body.appendChild(script);
    });
  }

  static registerKeys() {
    try {
      // Register media and special keys
      TIZEN_KEYS_TO_REGISTER.forEach((key) => {
        try {
          tizen.tvinputdevice.registerKey(key);
        } catch (e) {
          console.warn(`Failed to register key: ${key}`, e);
        }
      });
      console.log("Tizen keys registered successfully");
    } catch (e) {
      console.error("Failed to register Tizen keys:", e);
    }
  }

  static async initialize() {
    await TizenDevice.addScript();
    TizenDevice.registerKeys();
    return new TizenDevice(EDeviceType.TIZEN);
  }

  async closeApp() {
    tizen.application.getCurrentApplication().exit();
  }

  protected _getPlayer() {
    return new TizenPlayer();
  }
}
