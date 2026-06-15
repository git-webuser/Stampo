cask "stampo" do
  version "0.4.0"
  sha256 "f30d16448845da67d0106b6f8e81839f6c5128ac94bcbb1e90574a7c51eed070"

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
