#!/bin/bash
# ── Tests: lib/container.sh ───────────────────────────────────
# Container functions require proot-distro (Termux-only), so we
# test function existence and argument validation.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/container.sh"

test_start "lib/container.sh — Container System"

# ── Function existence ─────────────────────────────────────────
describe "Core container functions"

  it "container_available is defined" && {
    declare -f container_available &>/dev/null
    assert_ok $?
  }

  it "container_install is defined" && {
    declare -f container_install &>/dev/null
    assert_ok $?
  }

  it "container_login is defined" && {
    declare -f container_login &>/dev/null
    assert_ok $?
  }

  it "container_exec is defined" && {
    declare -f container_exec &>/dev/null
    assert_ok $?
  }

  it "container_exec_here is defined" && {
    declare -f container_exec_here &>/dev/null
    assert_ok $?
  }

  it "container_remove is defined" && {
    declare -f container_remove &>/dev/null
    assert_ok $?
  }

  it "container_reset is defined" && {
    declare -f container_reset &>/dev/null
    assert_ok $?
  }

  it "container_list is defined" && {
    declare -f container_list &>/dev/null
    assert_ok $?
  }

  it "container_list_available is defined" && {
    declare -f container_list_available &>/dev/null
    assert_ok $?
  }

  it "container_info is defined" && {
    declare -f container_info &>/dev/null
    assert_ok $?
  }

  it "container_pentest_setup is defined" && {
    declare -f container_pentest_setup &>/dev/null
    assert_ok $?
  }

# ── Distro resolution ─────────────────────────────────────────
describe "_container_resolve_distro"

  it "resolves 'ubuntu' to 'ubuntu'" && {
    result=$(_container_resolve_distro "ubuntu")
    assert_eq "$result" "ubuntu"
  }

  it "resolves 'kali' to 'kali-nethunter'" && {
    result=$(_container_resolve_distro "kali")
    assert_eq "$result" "kali-nethunter"
  }

  it "resolves 'nethunter' to 'kali-nethunter'" && {
    result=$(_container_resolve_distro "nethunter")
    assert_eq "$result" "kali-nethunter"
  }

  it "resolves 'alpine' to 'alpine'" && {
    result=$(_container_resolve_distro "alpine")
    assert_eq "$result" "alpine"
  }

  it "resolves 'debian' to 'debian'" && {
    result=$(_container_resolve_distro "debian")
    assert_eq "$result" "debian"
  }

  it "resolves 'fedora' to 'fedora'" && {
    result=$(_container_resolve_distro "fedora")
    assert_eq "$result" "fedora"
  }

  it "resolves 'arch' to 'archlinux'" && {
    result=$(_container_resolve_distro "arch")
    assert_eq "$result" "archlinux"
  }

  it "passes through unknown names" && {
    result=$(_container_resolve_distro "mysteryos")
    assert_eq "$result" "mysteryos"
  }

# ── Argument validation ───────────────────────────────────────
describe "Argument validation"

  it "container_install fails without name" && {
    container_install "" 2>/dev/null
    assert_fail $?
  }

  it "container_login fails without name" && {
    container_login "" 2>/dev/null
    assert_fail $?
  }

  it "container_exec fails without name" && {
    container_exec "" "" 2>/dev/null
    assert_fail $?
  }

  it "container_exec fails without command" && {
    container_exec "ubuntu" "" 2>/dev/null
    assert_fail $?
  }

  it "container_exec_here fails without name" && {
    container_exec_here "" "" 2>/dev/null
    assert_fail $?
  }

  it "container_remove fails without name" && {
    container_remove "" 2>/dev/null
    assert_fail $?
  }

  it "container_reset fails without name" && {
    container_reset "" 2>/dev/null
    assert_fail $?
  }

  it "container_info fails without name" && {
    container_info "" 2>/dev/null
    assert_fail $?
  }

# ── container_available ───────────────────────────────────────
describe "container_available"

  it "returns a status code" && {
    container_available
    status=$?
    # Either 0 (has proot-distro) or 1 (doesn't) — both valid
    assert_match "$status" "^[01]$"
  }

test_end
