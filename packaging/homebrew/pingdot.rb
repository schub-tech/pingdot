cask "pingdot" do
  version "0.1.1"
  sha256 "f1e36588f131b7d150453c1573d6b505590d649c8d60549b50e68b498125b1e7"

  url "https://github.com/schub-tech/pingdot/releases/download/v#{version}/PingDot-#{version}.zip"
  name "PingDot"
  desc "Menu bar dot that shows whether the internet works"
  homepage "https://www.schub.tech/labs/pingdot/"

  depends_on macos: :ventura

  app "PingDot.app"

  zap trash: "~/Library/Containers/tech.schub.pingdot"
end
