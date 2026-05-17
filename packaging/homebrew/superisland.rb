cask "superisland" do
  version "1.0.7"
  sha256 "REPLACE_WITH_RELEASE_DMG_SHA256"

  url "https://github.com/shobhit99/superisland/releases/download/v#{version}/SuperIsland.dmg"
  name "SuperIsland"
  desc "Interactive island for the Mac notch"
  homepage "https://dynamicisland.app/"

  depends_on macos: ">= :sonoma"

  app "SuperIsland.app"

  zap trash: [
    "~/Library/Application Support/SuperIsland",
    "~/Library/Caches/com.workview.SuperIsland",
    "~/Library/Preferences/com.workview.SuperIsland.plist",
  ]
end
