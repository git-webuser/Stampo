cask "stampo" do
  version "0.4.2"
  sha256 "d83c95fc2357bab8db65f644b916e41a6f40a69c23b4fa198dfec50a6cf0bdc5"

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
