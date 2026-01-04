import { DeviceConfig } from "#devices/devices";
import { merge } from "lodash-es";
import { config as common } from "#devices/common";
import { TizenDevice } from "./device";

export const config: DeviceConfig = merge({}, common, <Partial<DeviceConfig>>{
  name: "tizen",
  quality: {
    image: {
      ratio: 1,
      quality: 80,
    },
  },
  lightning: {
    rendererOptions: {
      numImageWorkers: 0,
    },
  },
  keys: {
    Back: 10009,
    Left: 37,
    Right: 39,
    Up: 38,
    Down: 40,
    Enter: 13,
    Play: 415,
    Pause: 19,
    PlayPause: 10252,
    FastForward: 417,
    FastForward10: 10233,
    Rewind: 412,
    Rewind10: 10232,
    Stop: 413,
    Key0: -1,
    Key1: -1,
    Key2: -1,
    Key3: -1,
    Key4: -1,
    Key5: -1,
    Key6: -1,
    Key7: -1,
    Key8: -1,
    Key9: -1,
  },
  keyHoldOptions: {
    userKeyHoldMap: {
      EnterHold: 13,
      BackHold: 10009,
    },
    holdThreshold: 1000,
  },
  initialize: async function () {
    return await TizenDevice.initialize();
  },
});
