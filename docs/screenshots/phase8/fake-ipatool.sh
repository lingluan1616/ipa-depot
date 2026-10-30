#!/bin/bash
# 假 ipatool（阶段五 / 六 / 七冒烟；阶段六增加 list-versions 与 get-version-metadata；
# 阶段七把 download 改为慢速假进度，可多个同时运行；阶段八原样复用）：模拟 auth info / revoke / login（含 2FA）/ search / download。
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
  "list-versions "*)
    e=$(cat "$LOGGED" 2>/dev/null); [ -n "$e" ] || { echo '{"level":"error","error":"failed to get account","success":false}'; exit 1; }
    echo "$(date +%H:%M:%S) list-versions-as $e" >> "$STATE/calls.log"
    echo '{"level":"info","externalVersionIdentifiers":[880000001,880000002,880000003],"success":true}'; exit 0;;
  "get-version-metadata "*)
    v=""; prev=""; for a in "$@"; do [ "$prev" = "-v" ] || [ "$prev" = "--external-version-id" ] && v="$a"; prev="$a"; done
    n=${v: -1}
    echo "{\"level\":\"info\",\"displayVersion\":\"3.8.$n\",\"releaseDate\":\"2026-0$n-01T00:00:00Z\",\"success\":true}"; exit 0;;
  "download "*)
    e=$(cat "$LOGGED" 2>/dev/null)
    out=""; id=0; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; [ "$prev" = "-i" ] && id="$a"; prev="$a"; done
    echo "$(date +%H:%M:%S) download-as $e id=$id pid=$$ start" >> "$STATE/calls.log"
    if [ -f "$STATE/fail-once" ]; then rm -f "$STATE/fail-once"; echo '{"level":"error","error":"Get \"https://p25-buy.itunes.apple.com/x\": unexpected EOF","success":false}'; exit 1; fi
    # 每个任务大小与速度不同（按 App id 区分）：总量 total MB，每 0.5 秒前进 step MB；.tmp 每步只追加 100 KB（省磁盘）
    total=$(( 60 + (id % 7) * 15 )); step=$(( 1 + id % 3 )); done_mb=0
    while [ $done_mb -lt $total ]; do
      head -c 100000 /dev/zero >> "$out.tmp"
      done_mb=$(( done_mb + step )); [ $done_mb -gt $total ] && done_mb=$total
      pct=$(( done_mb * 100 / total )); bars=$(( pct / 5 ))
      bar=$(printf '%*s' "$bars" '' | tr ' ' '#'); pad=$(printf '%*s' $(( 20 - bars )) '')
      printf 'downloading %3d%% |%s%s| (%d/%d MB, %d.0 MB/s)\r' "$pct" "$bar" "$pad" "$done_mb" "$total" $(( step * 2 ))
      sleep 0.5
    done
    # 不正常结束（避免进入校验）：一直等到被暂停 / 取消（短 sleep，被终止后不留长时间的孤儿 sleep）
    while true; do sleep 0.5; done;;
esac
echo '{"level":"error","error":"fake ipatool: unsupported command","success":false}'; exit 1
