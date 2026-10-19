#!/usr/bin/env python3
"""
George Craftsman Workbench: Neovim PTY Bridge
Bridges standard I/O to a pseudo-terminal running Neovim with full terminal emulation.
"""
import sys
import os
import pty
import select
import termios
import struct
import fcntl
import signal

def set_window_size(fd, rows, cols):
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except Exception:
        pass

def main():
    filepath = sys.argv[1] if len(sys.argv) > 1 else ""
    cols = int(sys.argv[2]) if len(sys.argv) > 2 else 100
    rows = int(sys.argv[3]) if len(sys.argv) > 3 else 30

    master, slave = pty.openpty()
    set_window_size(master, rows, cols)

    pid = os.fork()
    if pid == 0:
        os.close(master)
        os.setsid()
        # Set controlling terminal
        try:
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        except Exception:
            pass

        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        if slave > 2:
            os.close(slave)

        os.environ["TERM"] = "xterm-256color"
        os.environ["COLORTERM"] = "truecolor"
        
        args = ["nvim"]
        if filepath:
            args.append(filepath)

        try:
            os.execvp("nvim", args)
        except Exception as e:
            sys.stderr.write(f"Failed to exec nvim: {e}\n")
            sys.exit(1)

    os.close(slave)

    # Set stdin to non-blocking
    try:
        fcntl.fcntl(sys.stdin.fileno(), fcntl.F_SETFL, os.O_NONBLOCK)
        fcntl.fcntl(master, fcntl.F_SETFL, os.O_NONBLOCK)
    except Exception:
        pass

    try:
        while True:
            rlist, _, _ = select.select([sys.stdin.fileno(), master], [], [], 0.1)

            if master in rlist:
                try:
                    data = os.read(master, 4096)
                    if not data:
                        break
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                except (OSError, IOError):
                    break

            if sys.stdin.fileno() in rlist:
                try:
                    data = sys.stdin.buffer.read()
                    if not data:
                        break

                    # Check for resize control sequence: \x1b]RESIZE:COLS:ROWS\x07
                    if b"\x1b]RESIZE:" in data:
                        parts = data.split(b"\x1b]RESIZE:")
                        # write everything before resize
                        if parts[0]:
                            os.write(master, parts[0])
                        for part in parts[1:]:
                            if b"\x07" in part:
                                resize_cmd, remainder = part.split(b"\x07", 1)
                                try:
                                    c_str, r_str = resize_cmd.decode().split(":")
                                    set_window_size(master, int(r_str), int(c_str))
                                    try:
                                        os.kill(pid, signal.SIGWINCH)
                                    except Exception:
                                        pass
                                except Exception:
                                    pass
                                if remainder:
                                    os.write(master, remainder)
                            else:
                                os.write(master, part)
                    else:
                        os.write(master, data)
                except (OSError, IOError):
                    pass

            # Check if child process died
            res = os.waitpid(pid, os.WNOHANG)
            if res[0] == pid:
                break
    except KeyboardInterrupt:
        pass
    finally:
        try:
            os.kill(pid, signal.SIGTERM)
            os.waitpid(pid, 0)
        except Exception:
            pass
        try:
            os.close(master)
        except Exception:
            pass

if __name__ == "__main__":
    main()
