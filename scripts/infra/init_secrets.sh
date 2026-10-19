#!/usr/bin/env bash
# First-run local secrets & encrypted keystore bootstrap.
# Never overwrites an existing value; never prints a secret.
#   $LODGE_DIR/.env                                  docker compose variables (SEARXNG_SECRET, BIND_ADDR)
#   $LODGE_DIR/.george/secrets.env                   API keys / wallet addresses, seeded from configs/secrets.env.example
#   $LODGE_DIR/.george/secrets/agent_keystore.key    0600 auto-unlock keyfile for agent-hot / agent-evm encrypted keystore
#   $LODGE_DIR/.george/wallets/wallet_library.json   untracked operator wallet library & tax provenance config
set -euo pipefail
LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
umask 077

_rand_hex() {
    if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32
    else head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}

_ensure_key() {  # file key value — append only if key is absent
    local f="$1" k="$2" v="$3"
    grep -qE "^${k}=" "$f" 2>/dev/null && return 0
    [ -s "$f" ] && [ "$(tail -c1 "$f")" != "" ] && printf '\n' >> "$f"
    printf '%s=%s\n' "$k" "$v" >> "$f"
    echo "  + $k added to ${f#"$LODGE_DIR"/}"
}

envf="$LODGE_DIR/.env"
touch "$envf"; chmod 600 "$envf"
_ensure_key "$envf" SEARXNG_SECRET "$(_rand_hex)"
_ensure_key "$envf" BIND_ADDR 127.0.0.1

mkdir -p "$LODGE_DIR/.george/secrets" "$LODGE_DIR/.george/wallets/keystore" "$LODGE_DIR/.george/sdr"
chmod 700 "$LODGE_DIR/.george" "$LODGE_DIR/.george/secrets" "$LODGE_DIR/.george/wallets" "$LODGE_DIR/.george/wallets/keystore"

sec="$LODGE_DIR/.george/secrets.env"
if [ ! -e "$sec" ]; then
    if [ -f "$LODGE_DIR/configs/secrets.env.example" ]; then
        cp "$LODGE_DIR/configs/secrets.env.example" "$sec"
        echo "  + .george/secrets.env created from configs/secrets.env.example (fill in the services you use)"
    elif [ -f "$LODGE_DIR/config/secrets.env.example" ]; then
        cp "$LODGE_DIR/config/secrets.env.example" "$sec"
        echo "  + .george/secrets.env created from config/secrets.env.example (fill in the services you use)"
    fi
fi
[ -e "$sec" ] && chmod 600 "$sec"

akf="$LODGE_DIR/.george/secrets/agent_keystore.key"
if [ ! -e "$akf" ]; then
    _rand_hex > "$akf"
    chmod 600 "$akf"
    echo "  + .george/secrets/agent_keystore.key generated (0600)"
fi

wlib="$LODGE_DIR/.george/wallets/wallet_library.json"
if [ ! -e "$wlib" ] && [ -f "$LODGE_DIR/configs/wallets/wallet_library.example.json" ]; then
    cp "$LODGE_DIR/configs/wallets/wallet_library.example.json" "$wlib"
    chmod 600 "$wlib"
    echo "  + .george/wallets/wallet_library.json seeded from configs/wallets/wallet_library.example.json"
fi

echo "  ✓ local secrets ready (.env, .george/secrets.env, .george/secrets/agent_keystore.key are 0600 and git-ignored)"
