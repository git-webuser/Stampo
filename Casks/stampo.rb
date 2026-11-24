cask "stampo" do
  version "0.10.0"
  sha256 "7e6c8106f130fbdcfe4184e23357398d7aa1cac6e65987be32d3d02d545147f7"

  url "https://github.com/git-webuser/Stampo/releases/download/#{version}/Stampo-#{version}.dmg"
  name "Stampo"
  desc "Screenshot and color picker for MacBooks with a notch"
  homepage "https://git-webuser.github.io/Stampo/"

  depends_on macos: ">= :sequoia"

  app "Stampo.app"

  caveats <<~EOS
    Stampo is not notarized yet, so macOS blocks the first launch. Allow it
    via System Settings -> Privacy & Security -> Open Anyway,
    or remove the quarantine mark in Terminal:

      xattr -dr com.apple.quarantine /Applications/Stampo.app
  EOS

  zap trash: [
    "~/Library/Application Support/Stampo",
    "~/Library/Preferences/com.hex000.Stampo.plist",
  ]
end
