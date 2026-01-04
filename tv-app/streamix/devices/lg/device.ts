import { EDeviceType } from "#devices/devices";
import { DeviceCommon } from "#devices/common/device";
import { LgPlayer } from "./player";

export class LgDevice extends DeviceCommon {
  static async initialize() {
    return new LgDevice(EDeviceType.LG);
  }

  protected _getPlayer() {
    return new LgPlayer();
  }
}
