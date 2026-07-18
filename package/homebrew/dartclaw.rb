class Dartclaw < Formula
  desc "Security-conscious AI agent runtime"
  homepage "https://github.com/DartClaw/dartclaw"
  version "0.21.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/DartClaw/dartclaw/releases/download/v#{version}/dartclaw-v#{version}-macos-arm64.tar.gz"
      sha256 "1111111111111111111111111111111111111111111111111111111111111111"
    end

    on_intel do
      url "https://github.com/DartClaw/dartclaw/releases/download/v#{version}/dartclaw-v#{version}-macos-x64.tar.gz"
      sha256 "2222222222222222222222222222222222222222222222222222222222222222"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/DartClaw/dartclaw/releases/download/v#{version}/dartclaw-v#{version}-linux-x64.tar.gz"
      sha256 "3333333333333333333333333333333333333333333333333333333333333333"
    end

    on_arm do
      url "https://github.com/DartClaw/dartclaw/releases/download/v#{version}/dartclaw-v#{version}-linux-arm64.tar.gz"
      sha256 "4444444444444444444444444444444444444444444444444444444444444444"
    end
  end

  def install
    bin.install "bin/dartclaw"
    lib.install Dir["lib/*"]
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/dartclaw --version").strip
  end
end
