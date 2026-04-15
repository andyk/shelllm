#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/usr/local/bin}"
SYMLINKS="${SYMLINKS:-0}"
TOOLS=(shelllm shelly skills mem)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --symlinks) SYMLINKS=1; shift ;;
        --prefix)   PREFIX="${2:?--prefix requires a path}"; shift 2 ;;
        --help|-h)
            cat <<'EOF'
Usage: ./install.sh [options]

Installs shelllm, shelly, skills, and mem to a directory on your PATH.

Options:
  --prefix DIR   Install directory (default: /usr/local/bin)
  --symlinks     Create symlinks instead of copies (edits take effect without reinstalling)
  -h, --help     Show this help

Environment variables:
  PREFIX         Same as --prefix
  SYMLINKS=1     Same as --symlinks

Examples:
  ./install.sh                          # copy to /usr/local/bin
  ./install.sh --symlinks               # symlink to /usr/local/bin
  ./install.sh --prefix ~/.local/bin    # copy to ~/.local/bin
  PREFIX=~/bin SYMLINKS=1 ./install.sh  # symlink to ~/bin
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
done

for tool in "${TOOLS[@]}"; do
    if [[ "$SYMLINKS" -eq 1 ]]; then
        ln -sf "$(pwd)/$tool" "$PREFIX/$tool"
        echo "Linked $tool → $PREFIX/$tool"
    else
        cp "$tool" "$PREFIX/$tool"
        chmod +x "$PREFIX/$tool"
        echo "Installed $tool → $PREFIX/$tool"
    fi
done
