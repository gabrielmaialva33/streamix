const basePath = ""; //import.meta.env.BASE_URL;

export default [
  // NotoSans Bold (700) - has full Latin charset with accents
  {
    type: "msdf",
    fontFamily: "Roboto",
    descriptors: {
      weight: 700,
    },
    atlasDataUrl: basePath + "fonts/NotoSans-Bold.msdf.json",
    atlasUrl: basePath + "fonts/NotoSans-Bold.msdf.png",
  } as const,
  // NotoSans Regular (400) - has full Latin charset with accents
  {
    type: "msdf",
    fontFamily: "Roboto",
    descriptors: {
      weight: 400,
    },
    atlasDataUrl: basePath + "fonts/NotoSans-Regular.msdf.json",
    atlasUrl: basePath + "fonts/NotoSans-Regular.msdf.png",
  } as const,
  // NotoSans for medium weight (500) - use Regular as fallback
  {
    type: "msdf",
    fontFamily: "Roboto",
    descriptors: {
      weight: 500,
    },
    atlasDataUrl: basePath + "fonts/NotoSans-Regular.msdf.json",
    atlasUrl: basePath + "fonts/NotoSans-Regular.msdf.png",
  } as const,
  // NotoSans for light weight (300) - use Regular as fallback
  {
    type: "msdf",
    fontFamily: "Roboto",
    descriptors: {
      weight: 300,
    },
    atlasDataUrl: basePath + "fonts/NotoSans-Regular.msdf.json",
    atlasUrl: basePath + "fonts/NotoSans-Regular.msdf.png",
  } as const,
];
