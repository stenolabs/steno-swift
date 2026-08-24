#!/bin/bash

require_native_apple_silicon() {
    local detected_architecture="${1:-$(/usr/bin/uname -m)}"
    if [[ "$detected_architecture" != "arm64" ]]; then
        printf 'Steno supports native Apple Silicon only; found %s.\n' \
            "$detected_architecture" >&2
        return 1
    fi
}
