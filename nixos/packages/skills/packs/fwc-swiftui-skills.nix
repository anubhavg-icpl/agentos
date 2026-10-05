# FloWritesCode SwiftUI skills: Liquid Glass controls (iOS 26) and layouts
# for the foldable iPhone. Markdown only, no tools.
{ mkSkillPack, sources }:

mkSkillPack {
  pack = "fwc-swiftui-skills";
  version = "0-unstable-2026-10-05";
  src = sources.fwc-swiftui-skills;
  skills = {
    swiftui-liquid-glass = "skills/swiftui-liquid-glass";
    swiftui-iphone-duo = "skills/swiftui-iphone-duo";
  };
  description = "SwiftUI skills: Liquid Glass buttons and menus (iOS 26), iPhone Duo foldable layouts";
  homepage = "https://github.com/FloWritesCode/fwc-swiftui-skills";
  license = "MIT";
  collections = [ "design" ];
}
