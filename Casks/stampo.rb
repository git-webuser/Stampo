cask "stampo" do
  version "0.3.1"
  sha256 "0d69f6937435f0f9c4a3ea694b35125337ab9a50034b32b6126d11bd077cfd70"

  url "https://github.com/git-webuser/Stampo/releases/download/#{version}/Stampo-#{version}.dmg"
  name "Stampo"
  desc "Screenshot and color picker for MacBooks with a notch"
  homepage "https://github.com/git-webuser/Stampo"

  depends_on macos: ">= :sequoia"

  app "Stampo.app"

  caveats <<~EOS
    Stampo is not notarized yet. Install with --no-quarantine to skip the
    Gatekeeper warning:

      brew install --cask --no-quarantine stampo

    Or allow it after the first blocked launch via
    System Settings -> Privacy & Security -> Open Anyway.
  EOS

  zap trash: [
    "~/Library/Application Support/Stampo",
    "~/Library/Preferences/com.hex000.Stampo.plist",
  ]
end
