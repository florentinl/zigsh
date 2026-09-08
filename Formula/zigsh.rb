class Zigsh < Formula
  desc "Native Zsh module implemented in Zig"
  homepage "https://github.com/florentinl/zigsh"
  url "https://github.com/florentinl/zigsh/archive/790d9ba5c11c6eaaf9c75c68a48a8f1547d61010.tar.gz"
  version "0.1.0.11"
  sha256 "549fa7378942cd23964d830aba14960120b7cf56526574261bbfa2fde369ebab"
  license "MIT"

  bottle do
    root_url "https://github.com/florentinl/zigsh/releases/download/v0.1.0.11"
    sha256 cellar: :any, arm64_sonoma: "bfeff7536438686d3c96818fa5b3972c4d9f4ac19425918b99cfd6b2aaa2572c"
  end

  depends_on "autoconf" => :build
  depends_on "ncurses" => :build
  depends_on "zig" => :build

  def install
    system "zig", "build", "-Doptimize=ReleaseSafe",
           "-Dncurses-include=#{Formula["ncurses"].opt_include}"
    libexec.install "zig-out/lib/zigsh.so"
    prefix.install "packaging/zigsh.sh"
  end

  test do
    system "/bin/zsh", "-fc",
           "source #{prefix}/zigsh.sh; zmodload -e zigsh; zmodload -u zigsh"
  end
end
