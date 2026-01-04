import { EDevicePlatform, EDeviceType } from "#devices/devices";
import { createUniqueId } from "solid-js";
import { CommonPlayer } from "./player";

export class DeviceCommon {
  _player?: CommonPlayer;
  type: EDeviceType;
  platform: string;
  macAddress: string;
  osVersion: string;
  model: string;
  serialNumber: string;
  isUHD: boolean;
  canUpdate: boolean;

  constructor(
    type,
    platform: EDevicePlatform = EDevicePlatform.CHROME,
    osVersion: string = "0.0.0",
    model: string = "",
    serialNumber: string = "",
    isUHD: boolean = true,
    canUpdate: boolean = false,
  ) {
    this.macAddress = createUniqueId();
    this.type = type;
    this.platform = platform;
    this.osVersion = osVersion;
    this.model = model;
    this.serialNumber = serialNumber;
    this.isUHD = isUHD;
    this.canUpdate = canUpdate;
  }

  static async initialize(): Promise<DeviceCommon> {
    return new DeviceCommon(EDeviceType.EMULATOR);
  }

  async closeApp(): Promise<void> {
    console.log("should close the app");
    window.close();
  }

  async updateApp(): Promise<void> {
    console.log("should update the app");
  }

  getPlayer() {
    if (!this._player) this._player = this._getPlayer();
    return this._player;
  }

  protected _getPlayer() {
    return new CommonPlayer();
  }
}
