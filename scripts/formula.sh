#!/bin/sh
# Prints the Homebrew formula for a release. Used by the release workflow to update the tap,
# and by hand to test a formula locally before publishing.
#
#   scripts/formula.sh 0.1.0 <sha256> [archive-url] > Formula/ripe.rb
set -eu

version="${1:?usage: formula.sh <version> <sha256> [archive-url]}"
sha256="${2:?usage: formula.sh <version> <sha256> [archive-url]}"
url="${3:-https://github.com/imrajyavardhan12/ripe/releases/download/v${version}/ripe-${version}-universal-macos.tar.gz}"

cat <<EOF
class Ripe < Formula
  desc "See and update every outdated app on your Mac"
  homepage "https://github.com/imrajyavardhan12/ripe"
  url "${url}"
  version "${version}"
  sha256 "${sha256}"
  license "MIT"

  depends_on macos: :sonoma

  def install
    bin.install "ripe"
    generate_completions_from_executable(bin/"ripe", "--generate-completion-script")
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/ripe --version")
    # Runs discovery and the whole pipeline without touching the network: no app matches,
    # so no source has work, and the catalog is off.
    ENV["RIPE_CATALOG_URL"] = "none"
    ENV["RIPE_CACHE_DIR"] = testpath/"cache"
    assert_match "No app named", shell_output("#{bin}/ripe why homebrew-formula-test 2>&1", 1)
  end
end
EOF
