cask "pingdot" do
  version "0.2.0"
  sha256 "5ae5a6601281e8d01cf5e558a5d2a7b8178c60862d4fa30ba142ecd759655946"

  url "https://github.com/schub-tech/pingdot/releases/download/v#{version}/PingDot-#{version}.zip"
  name "PingDot"
  desc "Menu bar dot that shows whether the internet works"
  homepage "https://www.schub.tech/labs/pingdot/"

  depends_on macos: :ventura

  app "PingDot.app"

  zap trash: "~/Library/Containers/tech.schub.pingdot"
end
