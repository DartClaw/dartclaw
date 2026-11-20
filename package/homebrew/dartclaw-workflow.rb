class DartclawWorkflow < Formula
  desc "Workflow-only DartClaw runner (standalone, no server)"
  homepage "https://github.com/DartClaw/dartclaw"
  version "0.28.1"
  license "MIT"

  # Releases carry no Intel Mac archive, so Homebrew refuses an Intel Mac by name.
  on_macos do
    depends_on arch: :arm64
    url "https://github.com/DartClaw/dartclaw/releases/download/v#{version}/dartclaw-workflow-v#{version}-macos-arm64.tar.gz"
    sha256 "1111111111111111111111111111111111111111111111111111111111111111"
  end

  on_linux do
    on_intel do
      url "https://github.com/DartClaw/dartclaw/releases/download/v#{version}/dartclaw-workflow-v#{version}-linux-x64.tar.gz"
      sha256 "2222222222222222222222222222222222222222222222222222222222222222"
    end

    on_arm do
      url "https://github.com/DartClaw/dartclaw/releases/download/v#{version}/dartclaw-workflow-v#{version}-linux-arm64.tar.gz"
      sha256 "3333333333333333333333333333333333333333333333333333333333333333"
    end
  end

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/dartclaw-workflow"
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/dartclaw-workflow --version").strip
  end
end
