class Zigsh < Formula
  desc "Native Zsh module implemented in Zig"
  homepage "https://github.com/florentinl/zigsh"
  url "https://github.com/florentinl/zigsh/archive/0d4f4a455a583e2f8c2f9be03c0693c3476ed9d4.tar.gz"
  version "0.1.0.10"
  sha256 "474672920a10df4182205c654b91f772ff1d2ee49aad95f98c688f75ff89efba"
  license "MIT"

  bottle do
    root_url "https://github.com/florentinl/zigsh/releases/download/v0.1.0.10"
    sha256 cellar: :any, arm64_sonoma: "b95b9703a0d5324285cdfd5923d0b42bc794a78dfc8feab438a79ebf61625c86"
  end

  depends_on "autoconf" => :build
  depends_on "ncurses" => :build
  depends_on "zig" => :build
  depends_on "zsh"

  def install
    system "zig", "build", "-Doptimize=ReleaseSafe",
           "-Dncurses-include=#{Formula["ncurses"].opt_include}"
    libexec.install "zig-out/lib/zigsh.so"
    prefix.install "packaging/zigsh.sh"
  end

  test do
    system Formula["zsh"].opt_bin/"zsh", "-fc",
           "source #{prefix}/zigsh.sh; zmodload -e zigsh; zmodload -u zigsh"
  end
end
