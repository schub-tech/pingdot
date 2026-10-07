# Template — Scripts/release.sh fills in version and checksum and writes pingdot.rb.
cask "pingdot" do
  version "0.1.0"
  sha256 "e9a3270df6a2a7a9dde97693114ca037ae01e3373e88ccb9126f90e000e4e3fd"

  url "https://github.com/schub-tech/pingdot/releases/download/v#{version}/PingDot-#{version}.zip"
  name "PingDot"
  desc "Menu bar dot that shows whether the internet works"
  homepage "https://www.schub.tech/labs/pingdot/"

  depends_on macos: ">= :ventura"

  app "PingDot.app"

  zap trash: "~/Library/Containers/tech.schub.pingdot"
end
