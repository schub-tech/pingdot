cask "pingdot" do
  version "0.1.2"
  sha256 "157d44d6696af5217e937d37edd1b8879bda4a08b3fa265f1ce9ae2e73ebef59"

  url "https://github.com/schub-tech/pingdot/releases/download/v#{version}/PingDot-#{version}.zip"
  name "PingDot"
  desc "Menu bar dot that shows whether the internet works"
  homepage "https://www.schub.tech/labs/pingdot/"

  depends_on macos: :ventura

  app "PingDot.app"

  zap trash: "~/Library/Containers/tech.schub.pingdot"
end
