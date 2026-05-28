#!/usr/bin/env python3
"""电脑键盘 → 手机 terminal 直通(测试手机终端显示用)。

在电脑这边打的字(含方向键 / Ctrl+C / 中文等裸字节)经 adb forward 直接进手机 app 当前
打开的终端 channel。配合 app 的 DebugInputServer(debug build + 已 push hosts.json 才监听)。

前置:先跑 scripts/setup-mac-host.sh,并在手机上进入一个 project 终端(claude-main)。
用法:python3 scripts/term-relay.py [port]   退出:Ctrl+]
"""
import os
import select
import socket
import subprocess
import sys
import termios
import tty

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8889

subprocess.run(["adb", "forward", f"tcp:{PORT}", f"tcp:{PORT}"], check=False)
try:
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=5)
except OSError as e:
    print(f"[relay] 连不上 127.0.0.1:{PORT} —— app 在跑吗?跑过 setup-mac-host.sh 吗?({e})")
    sys.exit(1)

print(f"[relay] 已连 :{PORT}。在手机上进入一个 project 终端,这里打字直达手机。退出按 Ctrl+]。", flush=True)

fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
try:
    tty.setraw(fd)
    while True:
        r, _, _ = select.select([fd, sock], [], [])
        if fd in r:
            data = os.read(fd, 1024)
            if b"\x1d" in data:        # Ctrl+] → 退出(其余字节含 Ctrl+C 都原样发给手机)
                break
            sock.sendall(data)
        if sock in r:
            out = sock.recv(4096)      # app 一般只收输入;若回送(如 LocalEcho 提示)则显示
            if not out:
                termios.tcsetattr(fd, termios.TCSADRAIN, old)
                print("\r\n[relay] socket 关闭(app 退出/断开?)")
                break
            os.write(1, out)
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    print("\r\n[relay] 退出")
