#!/usr/bin/env bash
# =============================================================================
# ttci config — View or edit configuration
# =============================================================================
# Usage: ttci config [show|get <key>|edit|path]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

SUBCMD="${1:-show}"
shift 2>/dev/null || true

case "$SUBCMD" in
    show)
        cat "${TTCI_CONFIG}"
        ;;
    get)
        KEY="${1:?Usage: ttci config get <dotted.key>}"
        VALUE=$(yaml_get "${TTCI_CONFIG}" "$KEY")
        if [[ -n "$VALUE" ]]; then
            echo "$VALUE"
        else
            # Try list
            LIST=$(yaml_get_list "${TTCI_CONFIG}" "$KEY")
            if [[ -n "$LIST" ]]; then
                echo "$LIST"
            else
                log_error "Key not found: $KEY"
                exit 1
            fi
        fi
        ;;
    edit)
        EDITOR="${EDITOR:-vi}"
        "$EDITOR" "${TTCI_CONFIG}"
        ;;
    path)
        echo "${TTCI_CONFIG}"
        ;;
    --help|-h)
        echo "Usage: ttci config <subcommand>"
        echo ""
        echo "Subcommands:"
        echo "  show           Display full config (default)"
        echo "  get <key>      Get a specific config value (e.g., slurm.partition)"
        echo "  edit           Open config in \$EDITOR"
        echo "  path           Print config file path"
        ;;
    *)
        log_error "Unknown subcommand: $SUBCMD"
        echo "Run 'ttci config --help' for usage."
        exit 1
        ;;
esac
