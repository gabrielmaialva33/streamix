import { EDeviceType } from "@/managers/device";
import { DeviceCommon } from "#devices/common/device";
import { TizenPlayer } from "./player";

declare const tizen: any;

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

  static async initialize() {
    await TizenDevice.addScript();
    return new TizenDevice(EDeviceType.TIZEN);
  }

  async closeApp() {
    tizen.application.getCurrentApplication().exit();
  }

  protected _getPlayer() {
    return new TizenPlayer();
  }
}
