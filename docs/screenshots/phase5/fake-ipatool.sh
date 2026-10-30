#!/bin/bash
# 假 ipatool（阶段五冒烟）：模拟 auth info / revoke / login（含 2FA）/ search（按账号地区返回不同结果）/ download。
# 绝不调用真实 ipatool；状态放在脚本旁的 state/ 目录，Cookie 写在 $XDG_STATE_HOME/ipatool/cookies。
DIR="$(cd "$(dirname "$0")" && pwd)"
STATE="$DIR/state"
mkdir -p "$STATE"
LOGGED="$STATE/logged-in"
COOKIES="$XDG_STATE_HOME/ipatool/cookies"
echo "$(date +%H:%M:%S) $*" >> "$STATE/calls.log"
for a in "$@"; do case "$a" in -p|--password|*-pass) echo '{"level":"error","error":"password leaked into argv","success":false}'; exit 1;; esac; done

json_ok() { echo "{\"level\":\"info\",\"name\":\"$1\",\"email\":\"$2\",\"success\":true}"; }

case "$1 $2" in
  "--version "*) echo "ipatool version 2.7.0"; exit 0;;
  "auth info")
    if [ -s "$LOGGED" ]; then e=$(cat "$LOGGED"); json_ok "Smoke ${e%%@*}" "$e"; exit 0; fi
    echo '{"level":"error","error":"failed to get account: The specified item could not be found in the keychain.","success":false}'; exit 1;;
  "auth revoke")
    rm -f "$LOGGED"; echo "$(date +%H:%M:%S) revoke cookies=$(cat "$COOKIES" 2>/dev/null | tr '\n' ' ')" >> "$STATE/calls.log"
    echo '{"level":"info","success":true}'; exit 0;;
  "auth login")
    [ -t 0 ] || { echo '{"level":"error","error":"stdin is not a tty","success":false}'; exit 1; }
    printf 'enter Apple ID (email address or phone number): ' >&2; read -r email
    printf 'enter password: ' >&2; read -r pw
    echo '{"level":"info","message":"preparing authentication; the first login may take a few minutes"}'
    sleep 1.5
    expected="${email%%@*}-pass"
    [ "$pw" = "$expected" ] || { echo '{"level":"error","error":"failed to login: invalid password","success":false}'; exit 1; }
    echo "$(date +%H:%M:%S) login $email cookies-before=$(cat "$COOKIES" 2>/dev/null | tr '\n' ' ')" >> "$STATE/calls.log"
    # jp 账号视为受信任设备（不需要 2FA）；其他账号的 Cookie 里没有「<邮箱>-trusted」就要验证码
    if [ "$email" != "jp@example.test" ] && ! grep -q "$email-trusted" "$COOKIES" 2>/dev/null; then
      printf 'enter 2FA code: ' >&2; read -r code
      [ "$code" = "123456" ] || { echo '{"level":"error","error":"apple did not complete verification; try a fresh 2FA code","success":false}'; exit 1; }
      sleep 1
    fi
    mkdir -p "$(dirname "$COOKIES")"
    # 与 persistent-cookiejar 一样：合并已有 Cookie 再写回
    grep -q "$email-trusted" "$COOKIES" 2>/dev/null || echo "$email-trusted" >> "$COOKIES"
    echo "$email" > "$LOGGED"
    json_ok "Smoke ${email%%@*}" "$email"; exit 0;;
  "search "*)
    e=$(cat "$LOGGED" 2>/dev/null)
    case "$e" in
      jp@*) echo '{"level":"info","count":2,"apps":[{"id":1001,"bundleID":"jp.example.manga","name":"マンガ図書館（日本区）","version":"5.2.0","price":0,"platforms":["iphone"]},{"id":1002,"bundleID":"jp.example.train","name":"乗換案内（日本区）","version":"12.1","price":0,"platforms":["iphone","ipad"]}],"success":true}';;
      us@*) echo '{"level":"info","count":2,"apps":[{"id":2001,"bundleID":"us.example.stream","name":"Stream TV (US Store)","version":"8.4.1","price":0,"platforms":["iphone","ipad"]},{"id":2002,"bundleID":"us.example.bank","name":"Credit Union (US Store)","version":"3.0","price":0,"platforms":["iphone"]}],"success":true}';;
      *) echo '{"level":"error","error":"failed to get account","success":false}'; exit 1;;
    esac; exit 0;;
  "download "*)
    e=$(cat "$LOGGED" 2>/dev/null)
    echo "$(date +%H:%M:%S) download-as $e" >> "$STATE/calls.log"
    if [ -f "$STATE/fail-once" ]; then rm -f "$STATE/fail-once"; echo '{"level":"error","error":"Get \"https://p25-buy.itunes.apple.com/x\": unexpected EOF","success":false}'; exit 1; fi
    out=""; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    head -c 2000000 /dev/zero >> "$out.tmp"
    sleep 60; exit 0;;
esac
echo '{"level":"error","error":"fake ipatool: unsupported command","success":false}'; exit 1
