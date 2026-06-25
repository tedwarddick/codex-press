#!/usr/bin/env bash
set -euo pipefail

echo "Installing Codex Press dependencies..."

if ! command -v apt >/dev/null 2>&1; then
  echo "This installer is written for Debian/Ubuntu systems using apt."
  exit 1
fi

sudo apt update

sudo apt install -y \
  pandoc \
  texlive-xetex \
  texlive-latex-recommended \
  texlive-latex-extra \
  texlive-fonts-recommended \
  texlive-pictures \
  texlive-plain-generic \
  lmodern \
  fonts-texgyre \
  poppler-utils

echo
echo "Checking installed tools..."
command -v pandoc
command -v xelatex

echo
echo "Pandoc version:"
pandoc --version | head -n 1

echo
echo "XeLaTeX version:"
xelatex --version | head -n 1

echo
echo "Checking key LaTeX packages..."
kpsewhich scrbook.cls
kpsewhich tcolorbox.sty
kpsewhich tabularx.sty
kpsewhich fancyhdr.sty
kpsewhich microtype.sty
kpsewhich ulem.sty
kpsewhich enumitem.sty

echo
echo "Creating test PDF..."

cat > /tmp/codex-press-test.md <<'EOF'
# Codex Press Test

This is a test.

| One | Two | Three | Four |
|---|---|---|---|
| Alpha | Beta | Gamma | Delta |

EOF

pandoc /tmp/codex-press-test.md \
  -o /tmp/codex-press-test.pdf \
  --standalone \
  --pdf-engine=xelatex \
  -V documentclass=scrbook

echo
echo "Success. Test PDF created at:"
echo "/tmp/codex-press-test.pdf"
echo
echo "Done."
