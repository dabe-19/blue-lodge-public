#!/usr/bin/env python3
"""
Sovereign hot-wallet keystore for Blue Lodge (Cardano CIP-1852 + EVM).

Security model
--------------
* Secrets (BIP-39 mnemonics, raw keys) are encrypted at rest with AES-256-GCM using a
  key derived from the operator passphrase via scrypt (N=2^15, r=8, p=1). The wallet id
  and chain are bound as associated data, so ciphertexts cannot be swapped between files.
* Files live in .george/wallets/keystore/ (dir 0700, files 0600). Nothing secret is
  logged; passphrases/secrets reach this process via environment variables
  (LODGE_WALLET_PASSPHRASE / LODGE_WALLET_SECRET) which are popped immediately, never argv.
* The "agent-hot" wallet is encrypted at rest in .george/wallets/keystore/agent-hot.json
  and auto-unlocked via a 256-bit local vault keyfile (.george/secrets/agent_keystore.key,
  0600) or LODGE_AGENT_KEYSTORE_PASSPHRASE so George's background daemons (order watcher &
  Tier A reclaims) work unattended without plaintext .skey files on disk.
* Mnemonics are returned exactly once, at creation, for offline backup.
"""
from __future__ import annotations

import json
import os
import re
import secrets
import shutil
import sys
import time
import urllib.parse
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if __name__ == "__main__" and _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))
WALLETS_DIR = Path(os.environ.get("LODGE_WALLETS_DIR", GEORGE_DIR / "wallets"))
KEYSTORE_DIR = WALLETS_DIR / "keystore"
TRASH_DIR = KEYSTORE_DIR / ".trash"
ACTIVE_FILE = KEYSTORE_DIR / "active.json"
SECRETS_DIR = GEORGE_DIR / "secrets"
AGENT_KEYFILE = Path(os.environ.get("LODGE_AGENT_KEYFILE", SECRETS_DIR / "agent_keystore.key"))
BACKUPS_DIR = GEORGE_DIR / "backups"
AGENT_ID = "agent-hot"
AGENT_EVM_ID = "agent-evm"

SCRYPT_N, SCRYPT_R, SCRYPT_P = 2 ** 15, 8, 1
CARDANO_PAYMENT_PATH = "m/1852'/1815'/{acct}'/0/{idx}"
CARDANO_STAKE_PATH = "m/1852'/1815'/{acct}'/2/0"
EVM_PATH = "m/44'/60'/0'/0/{idx}"
ID_RE = re.compile(r"^[a-z0-9][a-z0-9\-]{2,40}$")
MIN_PASSPHRASE = 10


class KeystoreError(Exception):
    pass


# ---------------------------------------------------------------------------
# Crypto
# ---------------------------------------------------------------------------

def _kdf(passphrase: str, salt: bytes) -> bytes:
    from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
    return Scrypt(salt=salt, length=32, n=SCRYPT_N, r=SCRYPT_R, p=SCRYPT_P).derive(passphrase.encode("utf-8"))


def _encrypt(secret: str, passphrase: str, aad: bytes) -> Dict[str, str]:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    salt, nonce = secrets.token_bytes(16), secrets.token_bytes(12)
    ct = AESGCM(_kdf(passphrase, salt)).encrypt(nonce, secret.encode("utf-8"), aad)
    return {"kdf": "scrypt", "n": SCRYPT_N, "r": SCRYPT_R, "p": SCRYPT_P, "salt": salt.hex(),
            "cipher": "aes-256-gcm", "nonce": nonce.hex(), "ciphertext": ct.hex()}


def _decrypt(blob: Dict[str, Any], passphrase: str, aad: bytes) -> str:
    from cryptography.exceptions import InvalidTag
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
    key = Scrypt(salt=bytes.fromhex(blob["salt"]), length=32, n=int(blob["n"]), r=int(blob["r"]),
                 p=int(blob["p"])).derive(passphrase.encode("utf-8"))
    try:
        return AESGCM(key).decrypt(bytes.fromhex(blob["nonce"]), bytes.fromhex(blob["ciphertext"]), aad).decode()
    except InvalidTag:
        raise KeystoreError("wrong passphrase or corrupted keystore file") from None


def _aad(wallet_id: str, chain: str) -> bytes:
    return f"blue-lodge-keystore:v1:{wallet_id}:{chain}".encode()


# ---------------------------------------------------------------------------
# Storage & Agent Auto-Unlock Keyfile
# ---------------------------------------------------------------------------

def _ensure_dirs() -> None:
    for d in (WALLETS_DIR, KEYSTORE_DIR, TRASH_DIR, SECRETS_DIR, BACKUPS_DIR):
        d.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(d, 0o700)
        except OSError:
            pass


def _agent_passphrase(create_if_missing: bool = True) -> str:
    """Resolve the auto-unlock passphrase for agent-hot / agent-evm."""
    env_pw = os.environ.get("LODGE_AGENT_KEYSTORE_PASSPHRASE", "").strip()
    if env_pw:
        return env_pw
    _ensure_dirs()
    if AGENT_KEYFILE.exists():
        return AGENT_KEYFILE.read_text(encoding="utf-8").strip()
    if not create_if_missing:
        raise KeystoreError("agent keystore keyfile not found (.george/secrets/agent_keystore.key)")
    pw = secrets.token_hex(32)
    fd = os.open(str(AGENT_KEYFILE), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(pw + "\n")
    return pw


def _path(wallet_id: str) -> Path:
    if not ID_RE.match(wallet_id):
        raise KeystoreError("invalid wallet id")
    return KEYSTORE_DIR / f"{wallet_id}.json"


def _write_atomic(path: Path, data: Dict[str, Any]) -> None:
    tmp = path.with_suffix(".tmp")
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    tmp.replace(path)


def _load(wallet_id: str) -> Dict[str, Any]:
    p = _path(wallet_id)
    if not p.exists():
        raise KeystoreError(f"wallet '{wallet_id}' not found")
    return json.loads(p.read_text())


def _new_id(label: str, chain: str) -> str:
    base = re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")[:24] or chain
    return f"{chain[:3]}-{base}-{secrets.token_hex(3)}"


def _public(rec: Dict[str, Any]) -> Dict[str, Any]:
    return {k: v for k, v in rec.items() if k != "secret"}


def _check_passphrase(pw: Optional[str]) -> str:
    if not pw or len(pw) < MIN_PASSPHRASE:
        raise KeystoreError(f"passphrase must be at least {MIN_PASSPHRASE} characters")
    return pw


# ---------------------------------------------------------------------------
# Derivation
# ---------------------------------------------------------------------------

def _cardano_keys_from_mnemonic(mnemonic: str, account: int = 0, index: int = 0):
    from pycardano import ExtendedSigningKey, HDWallet
    w = HDWallet.from_mnemonic(mnemonic)
    pay = ExtendedSigningKey.from_hdwallet(w.derive_from_path(CARDANO_PAYMENT_PATH.format(acct=account, idx=index)))
    stake = ExtendedSigningKey.from_hdwallet(w.derive_from_path(CARDANO_STAKE_PATH.format(acct=account)))
    return pay, stake


def _cardano_addresses(pay_vk_hash, stake_vk_hash) -> Dict[str, str]:
    from pycardano import Address, Network
    return {"base": str(Address(pay_vk_hash, stake_vk_hash, Network.MAINNET)),
            "enterprise": str(Address(pay_vk_hash, network=Network.MAINNET)),
            "payment_key_hash": str(pay_vk_hash),
            "stake_key_hash": str(stake_vk_hash) if stake_vk_hash else None}


def _evm_account(secret: str, kind: str, index: int = 0):
    from eth_account import Account
    if kind == "mnemonic":
        Account.enable_unaudited_hdwallet_features()
        return Account.from_mnemonic(secret, account_path=EVM_PATH.format(idx=index))
    return Account.from_key(secret)


# ---------------------------------------------------------------------------
# Agent-Hot Migration & Auto-Unlock
# ---------------------------------------------------------------------------

def migrate_agent_hot(remove_plaintext: bool = True) -> Dict[str, Any]:
    """
    Encrypt legacy .george/wallets/cardano_payment.skey (and polygon_payment.key) into
    .george/wallets/keystore/agent-hot.json (and agent-evm.json) locked with the
    auto-unlock keyfile .george/secrets/agent_keystore.key (0600).
    """
    _ensure_dirs()
    pw = _agent_passphrase(create_if_missing=True)
    migrated: List[str] = []

    skey_file = WALLETS_DIR / "cardano_payment.skey"
    agent_json = _path(AGENT_ID)
    if skey_file.exists() and not agent_json.exists():
        from pycardano import PaymentSigningKey
        raw_json = json.loads(skey_file.read_text(encoding="utf-8"))
        cbor_hex = raw_json.get("cborHex", "").strip()
        if not cbor_hex:
            raise KeystoreError("cardano_payment.skey missing cborHex")
        sk = PaymentSigningKey.from_cbor(cbor_hex)
        vh = sk.to_verification_key().hash()
        addrs = _cardano_addresses(vh, None)
        addrs["primary"] = addrs["enterprise"]
        evm_addr = (WALLETS_DIR / "polygon_payment.addr").read_text().strip() if (WALLETS_DIR / "polygon_payment.addr").exists() else None
        rec = {
            "id": AGENT_ID,
            "label": "George agent hot wallet",
            "chain": "cardano",
            "kind": "cardano_skey_cbor",
            "encrypted": True,
            "auto_unlock": True,
            "delegated_to": "george",
            "addresses": addrs,
            "evm_address": evm_addr,
            "created_at": int(skey_file.stat().st_mtime),
            "secret": _encrypt(cbor_hex, pw, _aad(AGENT_ID, "cardano")),
        }
        _write_atomic(agent_json, rec)
        shutil.copy2(skey_file, BACKUPS_DIR / f"cardano_payment.skey.bak.{int(time.time())}")
        os.chmod(BACKUPS_DIR / f"cardano_payment.skey.bak.{int(time.time())}", 0o600)
        if remove_plaintext:
            skey_file.unlink()
        migrated.append(AGENT_ID)
        _audit("agent_hot_migrated", {"wallet_id": AGENT_ID, "address": addrs["primary"]})

    evm_key_file = WALLETS_DIR / "polygon_payment.key"
    evm_json = _path(AGENT_EVM_ID)
    if evm_key_file.exists() and not evm_json.exists():
        raw_hex = evm_key_file.read_text(encoding="utf-8").strip()
        if not raw_hex.startswith("0x"):
            raw_hex = "0x" + raw_hex
        acct = _evm_account(raw_hex, "privkey")
        rec_evm = {
            "id": AGENT_EVM_ID,
            "label": "George agent EVM wallet (Polygon/Ethereum)",
            "chain": "evm",
            "kind": "privkey",
            "encrypted": True,
            "auto_unlock": True,
            "delegated_to": "george",
            "addresses": {"primary": acct.address, "evm": acct.address},
            "created_at": int(evm_key_file.stat().st_mtime),
            "secret": _encrypt(raw_hex, pw, _aad(AGENT_EVM_ID, "evm")),
        }
        _write_atomic(evm_json, rec_evm)
        bak_p = BACKUPS_DIR / f"polygon_payment.key.bak.{int(time.time())}"
        shutil.copy2(evm_key_file, bak_p)
        os.chmod(bak_p, 0o600)
        if remove_plaintext:
            evm_key_file.unlink()
        migrated.append(AGENT_EVM_ID)
        _audit("agent_evm_migrated", {"wallet_id": AGENT_EVM_ID, "address": acct.address})

    return {"status": "ok", "migrated": migrated, "keyfile": str(AGENT_KEYFILE)}


def _agent_record() -> Optional[Dict[str, Any]]:
    agent_json = _path(AGENT_ID)
    if agent_json.exists():
        try:
            rec = _public(json.loads(agent_json.read_text(encoding="utf-8")))
            if not rec.get("evm_address") and _path(AGENT_EVM_ID).exists():
                evm_rec = json.loads(_path(AGENT_EVM_ID).read_text(encoding="utf-8"))
                rec["evm_address"] = evm_rec.get("addresses", {}).get("primary")
            return rec
        except Exception:
            pass
    skey = WALLETS_DIR / "cardano_payment.skey"
    if not skey.exists():
        return None
    from pycardano import PaymentSigningKey
    sk = PaymentSigningKey.load(str(skey))
    vh = sk.to_verification_key().hash()
    addrs = _cardano_addresses(vh, None)
    evm_addr = (WALLETS_DIR / "polygon_payment.addr").read_text().strip() if (WALLETS_DIR / "polygon_payment.addr").exists() else None
    return {"id": AGENT_ID, "label": "George agent hot wallet", "chain": "cardano", "kind": "legacy_plaintext_skey",
            "encrypted": False, "delegated_to": "george", "addresses": {**addrs, "primary": addrs["enterprise"]},
            "evm_address": evm_addr, "created_at": int(skey.stat().st_mtime),
            "warning": "Plaintext key on disk; run 'keystore.py migrate-agent' to encrypt at rest."}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def list_wallets() -> Dict[str, Any]:
    _ensure_dirs()
    out: List[Dict[str, Any]] = []
    agent = _agent_record()
    if agent:
        out.append(agent)
    for p in sorted(KEYSTORE_DIR.glob("*.json")):
        if p.name in ("active.json", f"{AGENT_ID}.json"):
            continue
        try:
            out.append(_public(json.loads(p.read_text())))
        except json.JSONDecodeError:
            continue
    active = json.loads(ACTIVE_FILE.read_text()).get("cardano") if ACTIVE_FILE.exists() else AGENT_ID
    return {"status": "ok", "wallets": out, "active_cardano": active or AGENT_ID}


def create_wallet(chain: str, label: str, passphrase: str, words: int = 24) -> Dict[str, Any]:
    _ensure_dirs()
    _check_passphrase(passphrase)
    if chain not in ("cardano", "evm"):
        raise KeystoreError("chain must be cardano or evm")
    from mnemonic import Mnemonic
    mnemonic = Mnemonic("english").generate(strength={12: 128, 15: 160, 24: 256}.get(words, 256))
    rec = _store(chain, label, "mnemonic", mnemonic, passphrase)
    return {"status": "ok", "wallet": _public(rec), "mnemonic": mnemonic,
            "backup_notice": "Write these words down offline now. They will not be shown again."}


def import_wallet(chain: str, label: str, kind: str, secret: str, passphrase: str) -> Dict[str, Any]:
    _ensure_dirs()
    _check_passphrase(passphrase)
    secret = secret.strip()
    if kind == "mnemonic":
        from mnemonic import Mnemonic
        secret = " ".join(secret.lower().split())
        if not Mnemonic("english").check(secret):
            raise KeystoreError("mnemonic checksum invalid")
    elif kind == "privkey":
        if chain != "evm" or not re.fullmatch(r"(0x)?[0-9a-fA-F]{64}", secret):
            raise KeystoreError("privkey import expects a 32-byte hex EVM key")
    elif kind == "cardano_skey_cbor":
        if chain != "cardano" or not re.fullmatch(r"[0-9a-fA-F]{68,200}", secret):
            raise KeystoreError("expected cardano signing key CBOR hex (cborHex field)")
    else:
        raise KeystoreError("kind must be mnemonic, privkey or cardano_skey_cbor")
    rec = _store(chain, label, kind, secret, passphrase)
    return {"status": "ok", "wallet": _public(rec)}


def _store(chain: str, label: str, kind: str, secret: str, passphrase: str) -> Dict[str, Any]:
    wid = _new_id(label, chain)
    if chain == "cardano":
        if kind == "mnemonic":
            pay, stake = _cardano_keys_from_mnemonic(secret)
            addrs = _cardano_addresses(pay.to_verification_key().hash(), stake.to_verification_key().hash())
            primary = addrs["base"]
        else:
            from pycardano import PaymentSigningKey
            sk = PaymentSigningKey.from_cbor(secret)
            addrs = _cardano_addresses(sk.to_verification_key().hash(), None)
            primary = addrs["enterprise"]
        addrs["primary"] = primary
    else:
        acct = _evm_account(secret, kind)
        addrs = {"primary": acct.address, "evm": acct.address}
    rec = {"id": wid, "label": label[:60], "chain": chain, "kind": kind, "encrypted": True,
           "derivation": CARDANO_PAYMENT_PATH.format(acct=0, idx=0) if (chain == "cardano" and kind == "mnemonic")
           else (EVM_PATH.format(idx=0) if kind == "mnemonic" else None),
           "addresses": addrs, "created_at": int(time.time()), "delegated_to": None,
           "secret": _encrypt(secret, passphrase, _aad(wid, chain))}
    _write_atomic(_path(wid), rec)
    _audit("wallet_created", {"wallet_id": wid, "chain": chain, "kind": kind})
    return rec


def unlock_secret(wallet_id: str, passphrase: Optional[str] = None) -> Tuple[Dict[str, Any], str]:
    rec = _load(wallet_id)
    eff_pw = passphrase
    if not eff_pw and (wallet_id in (AGENT_ID, AGENT_EVM_ID) or rec.get("auto_unlock")):
        eff_pw = _agent_passphrase(create_if_missing=False)
    if not eff_pw:
        raise KeystoreError("passphrase required to unlock this wallet")
    return rec, _decrypt(rec["secret"], eff_pw, _aad(wallet_id, rec["chain"]))


def cardano_signer(wallet_id: Optional[str], passphrase: Optional[str] = None):
    """(address, signing key) for Cardano transactions. None/'agent-hot' -> auto-unlocked agent key."""
    if wallet_id in (None, "", AGENT_ID):
        from pycardano import PaymentSigningKey
        if _path(AGENT_ID).exists():
            rec, secret = unlock_secret(AGENT_ID, passphrase)
            if rec["kind"] == "mnemonic":
                pay, _ = _cardano_keys_from_mnemonic(secret)
                return rec["addresses"]["primary"], pay
            return rec["addresses"]["primary"], PaymentSigningKey.from_cbor(secret)
        agent = _agent_record()
        if not agent:
            raise KeystoreError("agent hot wallet key not found")
        return agent["addresses"]["primary"], PaymentSigningKey.load(str(WALLETS_DIR / "cardano_payment.skey"))
    rec, secret = unlock_secret(wallet_id, passphrase)
    if rec["chain"] != "cardano":
        raise KeystoreError("not a Cardano wallet")
    if rec["kind"] == "mnemonic":
        pay, _ = _cardano_keys_from_mnemonic(secret)
        return rec["addresses"]["primary"], pay
    from pycardano import PaymentSigningKey
    return rec["addresses"]["primary"], PaymentSigningKey.from_cbor(secret)


def evm_signer(wallet_id: Optional[str] = None, passphrase: Optional[str] = None):
    """Return eth_account LocalAccount for EVM transactions."""
    target_id = wallet_id or AGENT_EVM_ID
    if target_id in (AGENT_ID, AGENT_EVM_ID) and _path(AGENT_EVM_ID).exists():
        rec, secret = unlock_secret(AGENT_EVM_ID, passphrase)
        return _evm_account(secret, rec["kind"])
    if target_id in (AGENT_ID, AGENT_EVM_ID):
        evm_key_file = WALLETS_DIR / "polygon_payment.key"
        if evm_key_file.exists():
            raw = evm_key_file.read_text(encoding="utf-8").strip()
            return _evm_account(raw if raw.startswith("0x") else "0x" + raw, "privkey")
        raise KeystoreError("agent EVM wallet not found")
    rec, secret = unlock_secret(target_id, passphrase)
    if rec["chain"] != "evm":
        raise KeystoreError("not an EVM wallet")
    return _evm_account(secret, rec["kind"])


def sign_message(wallet_id: str, message: str, passphrase: Optional[str]) -> Dict[str, Any]:
    if len(message) > 4096:
        raise KeystoreError("message too long (max 4096 chars)")
    if wallet_id == AGENT_ID or (wallet_id != AGENT_EVM_ID and _load(wallet_id)["chain"] == "cardano"):
        from pycardano import Network, cip8
        addr, sk = cardano_signer(wallet_id, passphrase)
        signed = cip8.sign(message, sk, attach_cose_key=True, network=Network.MAINNET)
        _audit("message_signed", {"wallet_id": wallet_id, "standard": "CIP-8", "chars": len(message)})
        return {"status": "ok", "standard": "CIP-8 COSE_Sign1", "address": addr, "signature": signed}
    from eth_account.messages import encode_defunct
    acct = evm_signer(wallet_id, passphrase)
    sig = acct.sign_message(encode_defunct(text=message))
    _audit("message_signed", {"wallet_id": wallet_id, "standard": "EIP-191", "chars": len(message)})
    return {"status": "ok", "standard": "EIP-191 personal_sign", "address": acct.address,
            "signature": sig.signature.hex() if hasattr(sig.signature, "hex") else str(sig.signature)}


def verify_message(chain: str, signature: Any, message: Optional[str] = None,
                   address: Optional[str] = None) -> Dict[str, Any]:
    if chain == "cardano":
        from pycardano import cip8
        r = cip8.verify(signature)
        ok = bool(r.get("verified")) and (message is None or r.get("message") == message)
        signer = str(r.get("signing_address"))
        if address:
            from pycardano import Address
            try:
                ok = ok and Address.from_primitive(address).payment_part == Address.from_primitive(signer).payment_part
            except Exception:
                ok = False
        return {"status": "ok", "verified": ok, "signer": signer, "message": r.get("message")}
    from eth_account import Account
    from eth_account.messages import encode_defunct
    rec = Account.recover_message(encode_defunct(text=message or ""), signature=signature)
    return {"status": "ok", "verified": address is None or rec.lower() == address.lower(), "signer": rec}


def set_active(wallet_id: str) -> Dict[str, Any]:
    _ensure_dirs()
    if wallet_id != AGENT_ID:
        if _load(wallet_id)["chain"] != "cardano":
            raise KeystoreError("only Cardano wallets can be the active trading wallet")
    _write_atomic(ACTIVE_FILE, {"cardano": wallet_id, "updated_at": int(time.time())})
    _audit("active_wallet_set", {"wallet_id": wallet_id})
    return {"status": "ok", "active_cardano": wallet_id}


def delete_wallet(wallet_id: str, passphrase: str) -> Dict[str, Any]:
    if wallet_id in (AGENT_ID, AGENT_EVM_ID):
        raise KeystoreError("the agent wallet cannot be deleted from the UI")
    unlock_secret(wallet_id, passphrase)  # proves possession before removal
    _ensure_dirs()
    dst = TRASH_DIR / f"{wallet_id}.{int(time.time())}.json"
    _path(wallet_id).replace(dst)
    _audit("wallet_trashed", {"wallet_id": wallet_id})
    return {"status": "ok", "trashed": wallet_id, "recoverable_from": str(dst)}


def balances(wallet_id: str) -> Dict[str, Any]:
    if wallet_id == AGENT_ID:
        rec = _agent_record()
    else:
        rec = _public(_load(wallet_id))
    if not rec:
        raise KeystoreError("wallet not found")
    if rec["chain"] == "cardano":
        from lib.tools.cardano_orders import bf_get
        addr = rec["addresses"]["primary"]
        info = bf_get(f"/addresses/{addr}", allow_404=True) or {"amount": []}
        amounts = {a["unit"]: int(a["quantity"]) for a in info.get("amount", [])}
        from lib.tools.quant.market_data import KNOWN_ASSETS
        unit_to_sym = {m["unit"]: (s, m["decimals"]) for s, m in KNOWN_ASSETS.items()}
        assets = []
        for unit, q in amounts.items():
            if unit == "lovelace":
                continue
            sym, dec = unit_to_sym.get(unit, (unit[56:][:16] or unit[:12], 0))
            assets.append({"unit": unit, "symbol": sym, "quantity": q / (10 ** dec)})
        return {"status": "ok", "wallet_id": wallet_id, "address": addr, "ada": amounts.get("lovelace", 0) / 1e6,
                "assets": assets, "explorer": f"https://cardanoscan.io/address/{addr}"}
    from lib.tools.sovereign_multichain_wallet import rpc_call, POLYGON_RPCS
    addr = rec["addresses"]["primary"]
    raw = rpc_call(POLYGON_RPCS, "eth_getBalance", [addr, "latest"])
    return {"status": "ok", "wallet_id": wallet_id, "address": addr, "pol": int(raw, 16) / 1e18,
            "explorer": f"https://polygonscan.com/address/{addr}"}


# ---------------------------------------------------------------------------
# Receive & Deposit Detection
# ---------------------------------------------------------------------------

def receive_info(
    wallet_id: Optional[str] = None,
    chain: Optional[str] = None,
    amount: Optional[float] = None,
    token: Optional[str] = None,
    memo: Optional[str] = None,
    check_incoming: bool = False,
) -> Dict[str, Any]:
    """
    Generate payment receiving address, payment URI (CIP-13 / EIP-681 / BIP-21 / Solana Pay),
    SVG + ANSI QR code, and optionally inspect recent incoming deposits.
    """
    from lib.tools.wallet import qr

    wid = wallet_id or AGENT_ID
    eff_chain = (chain or "").lower().strip()

    if wid == AGENT_ID and eff_chain in ("evm", "polygon", "ethereum", "eth", "pol"):
        wid = AGENT_EVM_ID

    rec: Optional[Dict[str, Any]] = None
    if wid == AGENT_ID:
        rec = _agent_record()
    elif wid == AGENT_EVM_ID and _path(AGENT_EVM_ID).exists():
        rec = _public(_load(AGENT_EVM_ID))
    elif _path(wid).exists():
        rec = _public(_load(wid))

    addr = ""
    stake_addr = None
    if rec:
        eff_chain = eff_chain or rec.get("chain", "cardano")
        addr = rec.get("addresses", {}).get("primary", "")
        stake_addr = rec.get("addresses", {}).get("base") if rec.get("addresses", {}).get("base") != addr else None
    else:
        # Check external / cold wallet library or multi-chain env vars
        eff_chain = eff_chain or "cardano"
        if eff_chain in ("evm", "polygon", "ethereum", "eth", "pol"):
            addr_p = WALLETS_DIR / "polygon_payment.addr"
            addr = addr_p.read_text().strip() if addr_p.exists() else os.environ.get("POLYMARKET_FUNDER_ADDRESS", "")
        elif eff_chain in ("btc", "bitcoin"):
            addr = os.environ.get("BTC_WALLET_ADDRESS", "")
        elif eff_chain in ("sol", "solana"):
            addr = os.environ.get("SOL_WALLET_ADDRESS", "")
        elif eff_chain in ("xrp", "ripple"):
            addr = os.environ.get("XRP_WALLET_ADDRESS", "")
        else:
            addr_p = WALLETS_DIR / "cardano_payment.addr"
            addr = addr_p.read_text().strip() if addr_p.exists() else os.environ.get("CARDANO_WALLET_ADDR", "")

    if not addr:
        raise KeystoreError(f"no receiving address configured for wallet='{wid}' chain='{eff_chain}'")

    # Construct standard payment URI
    params: Dict[str, str] = {}
    if amount is not None and amount > 0:
        params["amount"] = f"{amount:g}"
    if token:
        params["token"] = token.upper()
    if memo:
        params["message" if eff_chain == "cardano" else "memo"] = memo

    if eff_chain in ("cardano", "ada"):
        # CIP-13 URI: web+cardano:<address>?amount=<ada>
        q = urllib.parse.urlencode(params)
        payment_uri = f"web+cardano:{addr}" + (f"?{q}" if q else "")
        explorer_url = f"https://cardanoscan.io/address/{addr}"
    elif eff_chain in ("evm", "polygon", "pol", "ethereum", "eth"):
        chain_id = 1 if eff_chain in ("ethereum", "eth") else 137
        if amount is not None and amount > 0:
            wei = int(round(amount * 1e18))
            payment_uri = f"ethereum:{addr}@{chain_id}?value={wei}"
        else:
            payment_uri = f"ethereum:{addr}@{chain_id}"
        explorer_url = (
            f"https://etherscan.io/address/{addr}" if chain_id == 1 else f"https://polygonscan.com/address/{addr}"
        )
    elif eff_chain in ("btc", "bitcoin"):
        q = urllib.parse.urlencode(params)
        payment_uri = f"bitcoin:{addr}" + (f"?{q}" if q else "")
        explorer_url = f"https://mempool.space/address/{addr}"
    elif eff_chain in ("sol", "solana"):
        q = urllib.parse.urlencode(params)
        payment_uri = f"solana:{addr}" + (f"?{q}" if q else "")
        explorer_url = f"https://solscan.io/account/{addr}"
    else:
        payment_uri = addr
        explorer_url = ""

    qr_target = payment_uri if len(payment_uri) <= 180 else addr
    svg_str = qr.to_svg(qr_target)
    ansi_str = qr.to_ansi(qr_target)

    recent_txs: List[Dict[str, Any]] = []
    if check_incoming and eff_chain in ("cardano", "ada"):
        try:
            from lib.tools.cardano_orders import bf_get
            txs = bf_get(f"/addresses/{addr}/transactions?order=desc&count=5", allow_404=True) or []
            for t in txs[:5]:
                recent_txs.append({
                    "tx_hash": t.get("tx_hash"),
                    "block_time": t.get("block_time"),
                    "block_height": t.get("block_height"),
                    "explorer": f"https://cardanoscan.io/transaction/{t.get('tx_hash')}",
                })
        except Exception:
            pass

    return {
        "status": "ok",
        "wallet_id": wid,
        "chain": eff_chain,
        "address": addr,
        "stake_address": stake_addr,
        "requested_amount": amount,
        "requested_token": token,
        "memo": memo,
        "payment_uri": payment_uri,
        "uri": payment_uri,
        "explorer_url": explorer_url,
        "qr_svg": svg_str,
        "qr_ansi": ansi_str,
        "recent_transactions": recent_txs,
    }


# ---------------------------------------------------------------------------
# Send Cardano (ADA + Native Tokens by Symbol or Unit) & Send EVM
# ---------------------------------------------------------------------------

def _resolve_cardano_token(token_or_unit: str, token_amount: float) -> Tuple[str, int, str, int]:
    """Resolve symbol (e.g. 'SNEK', 'MIN', 'DJED') or raw hex unit -> (unit, base_qty, symbol, decimals)."""
    from lib.tools.quant import tokens as _tokens
    tbl = _tokens.unit_table()
    sym = token_or_unit.strip().upper()
    if sym in _tokens.ALIASES:
        sym = _tokens.ALIASES[sym]
    if sym in tbl:
        rec = tbl[sym]
        dec = int(rec.get("decimals", 0))
        qty = int(round(token_amount * (10 ** dec)))
        return rec["unit"], qty, sym, dec
    # Raw hex policy_id + asset_name
    if re.fullmatch(r"[0-9a-fA-F]{56,120}", token_or_unit.strip()):
        return token_or_unit.strip().lower(), int(round(token_amount)), token_or_unit[:12], 0
    raise KeystoreError(f"unknown Cardano token symbol or unit: '{token_or_unit}'")


def send_cardano(wallet_id: Optional[str], to_addr: str, ada: float, asset_unit: Optional[str] = None,
                 asset_qty: int = 0, passphrase: Optional[str] = None, execute: bool = False,
                 actor: str = "operator", policy_action: str = "send",
                 message: Optional[str] = None, token: Optional[str] = None,
                 token_amount: float = 0.0) -> Dict[str, Any]:
    from pycardano import (Address, Asset, AssetName, AuxiliaryData, BlockFrostChainContext, Metadata,
                           AlonzoMetadata, MultiAsset, Network, ScriptHash, TransactionBuilder,
                           TransactionOutput, Value)
    from lib.tools import cardano_orders as co
    from lib.tools.wallet import policy

    if policy_action not in ("send", "loan_disburse", "loan_return_collateral"):
        raise KeystoreError("unsupported policy action for a payment")

    resolved_sym = None
    if token and token.upper() != "ADA" and token_amount > 0:
        asset_unit, asset_qty, resolved_sym, _ = _resolve_cardano_token(token, token_amount)
        if ada <= 0:
            ada = 1.5  # Automatic min-UTxO ADA companion for native token transfers

    dest = Address.from_primitive(to_addr)
    if dest.network != Network.MAINNET:
        raise KeystoreError("destination is not a mainnet address")
    lovelace = int(round(ada * 1_000_000))
    if lovelace < 1_000_000:
        raise KeystoreError("minimum send is 1 ADA (UTxO minimum)")
    pol = policy.check(actor, policy_action, ada_out=ada, asset=resolved_sym, destination=to_addr,
                       wallet_id=wallet_id or AGENT_ID)
    if not pol["allowed"]:
        return {"status": "denied", "message": pol["reason"]}
    addr_str, sk = cardano_signer(wallet_id, passphrase)
    src = Address.from_primitive(addr_str)
    value = Value(lovelace)
    if asset_unit and asset_qty > 0:
        value = Value(lovelace, MultiAsset({ScriptHash(bytes.fromhex(asset_unit[:56])):
                                            Asset({AssetName(bytes.fromhex(asset_unit[56:])): int(asset_qty)})}))
    base, hdr = co._bf()
    ctx = BlockFrostChainContext(project_id=hdr["project_id"], base_url=base.rsplit("/v0", 1)[0], network=Network.MAINNET)
    b = TransactionBuilder(ctx)
    b.add_input_address(src)
    b.add_output(TransactionOutput(dest, value))
    if message:
        # CIP-20 transaction message (label 674), 64-byte chunks.
        msg = str(message)[:256]
        chunks = [msg[i:i + 64] for i in range(0, len(msg), 64)]
        b.auxiliary_data = AuxiliaryData(AlonzoMetadata(metadata=Metadata({674: {"msg": chunks}})))
    tx = b.build_and_sign(signing_keys=[sk], change_address=src)
    res = {"status": "ok", "chain": "cardano", "dry_run": not execute, "tx_id": str(tx.id),
           "fee_ada": tx.transaction_body.fee / 1e6, "from": addr_str, "to": to_addr, "ada": ada,
           "token": resolved_sym, "token_amount": token_amount if resolved_sym else None,
           "asset_unit": asset_unit, "asset_qty": asset_qty, "message": message,
           "cardanoscan_url": f"https://cardanoscan.io/transaction/{tx.id}"}
    if not execute:
        return res
    before = co.wallet_balance(addr_str)
    ctx.submit_tx(tx)
    policy.record_spend(actor, ada, str(tx.id))
    _audit("send_submitted", {"wallet_id": wallet_id or AGENT_ID, "chain": "cardano", "tx_id": str(tx.id),
                              "ada": ada, "token": resolved_sym, "actor": actor, "policy_action": policy_action})
    deadline = time.time() + 180
    while time.time() < deadline:
        if co.bf_get(f"/txs/{tx.id}", allow_404=True):
            after = co.wallet_balance(addr_str)
            res["confirmed"] = True
            res["wallet_delta"] = {u: after.get(u, 0) - before.get(u, 0) for u in set(after) | set(before)
                                   if after.get(u, 0) != before.get(u, 0)}
            return res
        time.sleep(10)
    res["confirmed"] = False
    return res


def send_evm(
    wallet_id: Optional[str],
    to_addr: str,
    amount: float,
    token: str = "POL",
    network: str = "polygon",
    passphrase: Optional[str] = None,
    execute: bool = False,
    actor: str = "operator",
) -> Dict[str, Any]:
    """
    Build, sign, and optionally broadcast an EVM native (POL/ETH) or ERC-20 (USDC/USDC.e)
    transfer on Polygon (Chain 137) or Ethereum (Chain 1).
    """
    from eth_utils import to_checksum_address
    from lib.tools.sovereign_multichain_wallet import (
        ETH_CHAIN_ID,
        ETH_RPCS,
        ETH_USDC_CONTRACT,
        POLYGON_BRIDGED_USDC,
        POLYGON_CHAIN_ID,
        POLYGON_NATIVE_USDC,
        POLYGON_RPCS,
        rpc_call,
    )
    from lib.tools.wallet import policy

    if amount <= 0:
        raise KeystoreError("send amount must be positive")
    pol = policy.check(actor, "send", ada_out=amount, asset=token, destination=to_addr,
                       wallet_id=wallet_id or AGENT_EVM_ID)
    if not pol["allowed"]:
        return {"status": "denied", "message": pol["reason"]}

    acct = evm_signer(wallet_id, passphrase)
    dest_checksum = to_checksum_address(to_addr.strip())
    net = network.lower().strip()
    is_eth = net in ("ethereum", "eth", "1")
    rpcs = ETH_RPCS if is_eth else POLYGON_RPCS
    chain_id = ETH_CHAIN_ID if is_eth else POLYGON_CHAIN_ID
    explorer_base = "https://etherscan.io" if is_eth else "https://polygonscan.com"

    tok = (token or ("ETH" if is_eth else "POL")).upper().strip()
    nonce = int(rpc_call(rpcs, "eth_getTransactionCount", [acct.address, "pending"]), 16)
    gas_price = int(int(rpc_call(rpcs, "eth_gasPrice", []), 16) * 1.15)

    if tok in ("POL", "MATIC", "ETH"):
        value_wei = int(round(amount * 1e18))
        tx_dict = {
            "nonce": nonce,
            "to": dest_checksum,
            "value": value_wei,
            "gas": 21000,
            "gasPrice": gas_price,
            "chainId": chain_id,
        }
    elif tok in ("USDC", "USDC.E", "BRIDGED_USDC"):
        if is_eth:
            contract = to_checksum_address(ETH_USDC_CONTRACT)
        elif tok in ("USDC.E", "BRIDGED_USDC"):
            contract = to_checksum_address(POLYGON_BRIDGED_USDC)
        else:
            contract = to_checksum_address(POLYGON_NATIVE_USDC)
        units = int(round(amount * 1_000_000))
        data_hex = "0xa9059cbb" + dest_checksum[2:].lower().rjust(64, "0") + hex(units)[2:].rjust(64, "0")
        tx_dict = {
            "nonce": nonce,
            "to": contract,
            "value": 0,
            "gas": 75000,
            "gasPrice": gas_price,
            "data": bytes.fromhex(data_hex[2:]),
            "chainId": chain_id,
        }
    else:
        raise KeystoreError(f"unsupported EVM token '{tok}' (supported: POL, ETH, USDC, USDC.e)")

    signed = acct.sign_transaction(tx_dict)
    tx_hash_hex = signed.hash.hex()
    if not tx_hash_hex.startswith("0x"):
        tx_hash_hex = "0x" + tx_hash_hex
    fee_native = (tx_dict["gas"] * gas_price) / 1e18

    res = {
        "status": "ok",
        "chain": "ethereum" if is_eth else "polygon",
        "chain_id": chain_id,
        "dry_run": not execute,
        "tx_id": tx_hash_hex,
        "from": acct.address,
        "to": dest_checksum,
        "amount": amount,
        "token": tok,
        "fee_native": round(fee_native, 8),
        "explorer_url": f"{explorer_base}/tx/{tx_hash_hex}",
    }
    if not execute:
        return res

    raw_tx_hex = signed.raw_transaction.hex() if hasattr(signed, "raw_transaction") else signed.rawTransaction.hex()
    if not raw_tx_hex.startswith("0x"):
        raw_tx_hex = "0x" + raw_tx_hex
    broadcast_hash = rpc_call(rpcs, "eth_sendRawTransaction", [raw_tx_hex])
    res["tx_id"] = broadcast_hash
    res["explorer_url"] = f"{explorer_base}/tx/{broadcast_hash}"
    _audit("send_submitted", {"wallet_id": wallet_id or AGENT_EVM_ID, "chain": res["chain"], "tx_id": broadcast_hash,
                              "amount": amount, "token": tok, "actor": actor})
    return res


def _audit(kind: str, payload: Dict[str, Any]) -> None:
    p = GEORGE_DIR / "finance" / "wallet_audit.jsonl"
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, "a") as f:
        f.write(json.dumps({"ts": int(time.time()), "kind": kind, **payload}) + "\n")


def main() -> None:
    import argparse
    ap = argparse.ArgumentParser(description="Blue Lodge sovereign keystore")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    m = sub.add_parser("migrate-agent")
    m.add_argument("--keep-plaintext", action="store_true")
    c = sub.add_parser("create"); c.add_argument("--chain", required=True); c.add_argument("--label", required=True)
    c.add_argument("--words", type=int, default=24)
    i = sub.add_parser("import"); i.add_argument("--chain", required=True); i.add_argument("--label", required=True)
    i.add_argument("--kind", required=True)
    b = sub.add_parser("balance"); b.add_argument("--id", required=True)
    r = sub.add_parser("receive"); r.add_argument("--id", default=AGENT_ID); r.add_argument("--chain")
    r.add_argument("--amount", type=float); r.add_argument("--token"); r.add_argument("--memo")
    r.add_argument("--check-incoming", action="store_true")
    s = sub.add_parser("sign"); s.add_argument("--id", required=True); s.add_argument("--message", required=True)
    v = sub.add_parser("verify"); v.add_argument("--chain", required=True); v.add_argument("--signature", required=True)
    v.add_argument("--message"); v.add_argument("--address")
    a = sub.add_parser("set-active"); a.add_argument("--id", required=True)
    d = sub.add_parser("delete"); d.add_argument("--id", required=True)
    se = sub.add_parser("send"); se.add_argument("--id", default=AGENT_ID); se.add_argument("--chain", default="cardano")
    se.add_argument("--to", required=True); se.add_argument("--ada", type=float, default=0.0)
    se.add_argument("--amount", type=float, default=0.0); se.add_argument("--token")
    se.add_argument("--asset-unit"); se.add_argument("--asset-qty", type=int, default=0)
    se.add_argument("--message"); se.add_argument("--execute", action="store_true")
    se.add_argument("--actor", default="operator")
    p = sub.add_parser("policy"); p.add_argument("--set", help="JSON policy document")
    args = ap.parse_args()
    pw = os.environ.pop("LODGE_WALLET_PASSPHRASE", None)
    secret = os.environ.pop("LODGE_WALLET_SECRET", None)
    try:
        if args.cmd == "list":
            res = list_wallets()
        elif args.cmd == "migrate-agent":
            res = migrate_agent_hot(remove_plaintext=not args.keep_plaintext)
        elif args.cmd == "create":
            res = create_wallet(args.chain, args.label, pw or "", args.words)
        elif args.cmd == "import":
            res = import_wallet(args.chain, args.label, args.kind, secret or "", pw or "")
        elif args.cmd == "balance":
            res = balances(args.id)
        elif args.cmd == "receive":
            res = receive_info(args.id, args.chain, args.amount, args.token, args.memo, args.check_incoming)
        elif args.cmd == "sign":
            res = sign_message(args.id, args.message, pw)
        elif args.cmd == "verify":
            sig: Any = args.signature
            try:
                sig = json.loads(sig)
            except (json.JSONDecodeError, TypeError):
                pass
            res = verify_message(args.chain, sig, args.message, args.address)
        elif args.cmd == "set-active":
            res = set_active(args.id)
        elif args.cmd == "delete":
            res = delete_wallet(args.id, pw or "")
        elif args.cmd == "send":
            ch = (args.chain or "cardano").lower()
            if ch in ("evm", "polygon", "pol", "ethereum", "eth"):
                amt = args.amount if args.amount > 0 else args.ada
                res = send_evm(args.id, args.to, amt, token=args.token or ("ETH" if ch in ("ethereum", "eth") else "POL"),
                               network=ch, passphrase=pw, execute=args.execute, actor=args.actor)
            else:
                ada_amt = args.ada if args.ada > 0 else (args.amount if not args.token or args.token.upper() == "ADA" else 1.5)
                tok_amt = args.amount if (args.token and args.token.upper() != "ADA") else 0.0
                res = send_cardano(args.id, args.to, ada_amt, args.asset_unit, args.asset_qty, pw, args.execute,
                                   args.actor, message=args.message, token=args.token, token_amount=tok_amt)
        else:
            from lib.tools.wallet import policy
            if args.set:
                policy.save_policy(json.loads(args.set))
            res = {"status": "ok", "policy": policy.load_policy()}
    except KeystoreError as e:
        res = {"status": "error", "message": str(e)}
    except Exception as e:
        res = {"status": "error", "message": f"{type(e).__name__}: {e}"}
    print(json.dumps(res, indent=2, default=str))


if __name__ == "__main__":
    main()
