# Example app icon

All example targets require OS 26 or later.

- iOS and macOS share `../MPVUIExample/Shared/AppIcon.icon`, an Icon Composer document with vector foreground artwork. The default and dark backgrounds are explicitly black. The system supplies the outer mask and Liquid Glass effects.
- The mono artwork preserves the ribbon folds with a brighter grayscale ramp for clear and tinted appearances. These appearances use the system's background and tint.
- tvOS uses `AppIconTV.brandassets`: foreground ribbon and opaque black background layers at 400×240, 800×480, and 1280×768. The Icon Composer document is excluded from the tvOS target.

`AppIcon.svg` is the editable artwork source. Its centered 82% transform gives approximately 16% horizontal padding on the square icon canvas. Do not add rounded corners or a Mac-specific inset to the foreground artwork.

After editing the source, regenerate the Icon Composer SVG layers and tvOS foreground PNGs from the repository root:

```sh
npm install --prefix .build/icon-tools --no-package-lock --no-save @resvg/resvg-js@2.6.2
node Example/Artwork/generate-icons.mjs
```

The generator preserves the appearance and material settings in `AppIcon.icon/icon.json`. Open `AppIcon.icon` in Icon Composer to edit those settings. Preview default, dark, clear light/dark, and tinted light/dark appearances for both iOS and macOS before shipping.

Apple documentation: [Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer), [app icon guidelines](https://developer.apple.com/design/human-interface-guidelines/app-icons), and [tvOS asset catalogs](https://developer.apple.com/documentation/xcode/configuring-your-app-icon).
