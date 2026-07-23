cask "stampo" do
  version "0.6.0"
  sha256 "0b6bd3baed4f1523b3e4b17250e5faa69899282ec174d90b4f6bbe20c2ee8ed7"

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
