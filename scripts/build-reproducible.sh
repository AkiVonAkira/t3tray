#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD)
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for build in first second; do
  mkdir -p "$work/$build"
  git archive HEAD | tar -x -C "$work/$build"
  (
    cd "$work/$build"
    export RUSTFLAGS="--remap-path-prefix=$work/$build=/src --remap-path-prefix=$CARGO_HOME=/cargo --remap-path-prefix=$HOME/.rustup=/rust -C link-arg=-Wl,--no-insert-timestamp"
    cargo build --locked --release --target x86_64-pc-windows-gnu
  )
done
first="$work/first/target/x86_64-pc-windows-gnu/release/t3tray.exe"
second="$work/second/target/x86_64-pc-windows-gnu/release/t3tray.exe"
sha256sum "$first" "$second"
cmp "$first" "$second"
mkdir -p dist
cp "$first" dist/t3tray.exe
cp install.ps1 uninstall.ps1 dist/
# A tagged release fetches helpers from its own tag, not from main.
if [[ "${GITHUB_REF_NAME:-}" == v* ]]; then
  sed -i "s/^\$sourceRef = 'main'\$/\$sourceRef = '$GITHUB_REF_NAME'/" dist/install.ps1 dist/uninstall.ps1
  grep -q "^\$sourceRef = '$GITHUB_REF_NAME'\$" dist/install.ps1
  grep -q "^\$sourceRef = '$GITHUB_REF_NAME'\$" dist/uninstall.ps1
fi
(cd dist && sha256sum t3tray.exe install.ps1 uninstall.ps1 > SHA256SUMS)
echo 'Reproducibility verified: both clean builds are byte-identical.'
