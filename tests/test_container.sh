#!/bin/bash
# ── Tests: lib/sys/container.sh ───────────────────────────────────
# Container functions require proot-distro (Termux-only), so we
# test function existence and argument validation.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh"
source "$LODGE_DIR/lib/sys/container.sh"

test_start "lib/sys/container.sh — Container System"

# ── Function existence ─────────────────────────────────────────
describe "Core container functions"

  it "container_available is defined" && assert_fn_defined "container_available"
  it "container_install is defined" && assert_fn_defined "container_install"
  it "container_login is defined" && assert_fn_defined "container_login"
  it "container_exec is defined" && assert_fn_defined "container_exec"
  it "container_exec_here is defined" && assert_fn_defined "container_exec_here"
  it "container_remove is defined" && assert_fn_defined "container_remove"
  it "container_reset is defined" && assert_fn_defined "container_reset"
  it "container_list is defined" && assert_fn_defined "container_list"
  it "container_list_available is defined" && assert_fn_defined "container_list_available"
  it "container_info is defined" && assert_fn_defined "container_info"
  it "container_pentest_setup is defined" && assert_fn_defined "container_pentest_setup"

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

  it "container_install fails without name" && { container_install "" 2>/dev/null; assert_fail $?; }
  it "container_login fails without name" && { container_login "" 2>/dev/null; assert_fail $?; }
  it "container_exec fails without name" && { container_exec "" "" 2>/dev/null; assert_fail $?; }
  it "container_exec fails without command" && { container_exec "ubuntu" "" 2>/dev/null; assert_fail $?; }
  it "container_exec_here fails without name" && { container_exec_here "" "" 2>/dev/null; assert_fail $?; }
  it "container_remove fails without name" && { container_remove "" 2>/dev/null; assert_fail $?; }
  it "container_reset fails without name" && { container_reset "" 2>/dev/null; assert_fail $?; }
  it "container_info fails without name" && { container_info "" 2>/dev/null; assert_fail $?; }

# ── container_available ───────────────────────────────────────
describe "container_available"

  it "returns a status code" && {
    container_available
    status=$?
    # Either 0 (has proot-distro) or 1 (doesn't) — both valid
    assert_match "$status" "^[01]$"
  }

test_end
