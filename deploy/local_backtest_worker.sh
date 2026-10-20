#!/usr/bin/env bash
# 로컬 PC(WSL)에서 백테스트 API + LEAN을 실행하고 SSH 터널로 EC2 웹(/backtest)에 연결한다.
# EC2가 작아(디스크·메모리) LEAN 이미지(약 42GB)를 둘 수 없을 때 BACKTEST_MODE=local 배포와 함께 쓴다.
#
#   ./deploy/local_backtest_worker.sh install    systemd 사용자 서비스로 등록하고 시작 (WSL이 켜지면 자동 시작)
#   ./deploy/local_backtest_worker.sh status     서비스·터널·웹 연결 상태
#   ./deploy/local_backtest_worker.sh logs       로그 따라 보기
#   ./deploy/local_backtest_worker.sh restart    다시 시작
#   ./deploy/local_backtest_worker.sh uninstall  중지하고 서비스 삭제
#   ./deploy/local_backtest_worker.sh run        포그라운드 실행 (서비스가 내부적으로 사용)
#
# 연결 구조:
#   브라우저 → EC2 nginx /backtest/api → EC2 127.0.0.1:8002 ═(SSH 역터널)═► 이 PC 127.0.0.1:18002 백테스트 API → 이 PC Docker LEAN
#   이 PC 백테스트 API → 이 PC 127.0.0.1:15432 ═(SSH 터널)═► EC2 PostgreSQL (서버 배포가 찾은 DATABASE_URL)
#
# 환경변수(모두 선택): DEPLOY_HOST, SSH_KEY / KEY_DIR, SSH_USER(ubuntu), SSH_PORT(22),
#   LOCAL_API_PORT(18002, 로컬 개발용 8002와 겹치지 않게), REMOTE_API_PORT(8002), LOCAL_DB_PORT(15432)
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BACKTEST_DIR="$ROOT_DIR/backtester"
DEPLOY_HOST="${DEPLOY_HOST:-13.209.87.155}"
KEY_DIR="${KEY_DIR:-/home/l/stock-coin-trade}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_PORT="${SSH_PORT:-22}"
LOCAL_API_PORT="${LOCAL_API_PORT:-18002}"
REMOTE_API_PORT="${REMOTE_API_PORT:-8002}"
LOCAL_DB_PORT="${LOCAL_DB_PORT:-15432}"
LEAN_IMAGE="quantconnect/lean:latest"
SERVICE_NAME="limson-backtest-worker"
UNIT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$SERVICE_NAME.service"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$SERVICE_NAME"
REMOTE_APP_ENV="/etc/open-trading-api/app.env"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf '[실패] %s\n' "$*" >&2; exit 1; }

find_key() {
  if [[ -n "${SSH_KEY:-}" ]]; then
    [[ -f "$SSH_KEY" ]] || die "SSH_KEY 파일이 없습니다: $SSH_KEY"
    printf '%s\n' "$SSH_KEY"
    return 0
  fi
  local key
  key="$(find "$KEY_DIR" -maxdepth 3 -type f \( -name '*.pem' -o -name '*.key' \) 2>/dev/null | sort | head -n 1)"
  [[ -n "$key" ]] || die "$KEY_DIR 에서 *.pem / *.key 를 찾지 못했습니다 (SSH_KEY=키파일 로 지정)."
  printf '%s\n' "$key"
}

prepare_key() {  # WSL /mnt/c 키는 권한이 넓어 ssh가 거부하므로 600 사본을 쓴다
  mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
  install -m 600 "$(find_key)" "$STATE_DIR/ssh-key"
  KEY_FILE="$STATE_DIR/ssh-key"
}

ssh_opts() {
  SSH_OPTS=(
    -i "$KEY_FILE" -p "$SSH_PORT"
    -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10
    -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3
    -o LogLevel=ERROR
  )
}

remote() { ssh "${SSH_OPTS[@]}" "$SSH_USER@$DEPLOY_HOST" "$@"; }

# 서버 배포(server_setup.sh)가 찾아 둔 DATABASE_URL을 읽어 "DB호스트 DB포트 로컬DSN" 을 만든다.
resolve_db() {
  local dsn
  dsn="$(remote "sudo -n sed -n 's/^DATABASE_URL=//p' $REMOTE_APP_ENV 2>/dev/null | tail -n 1")" || return 1
  [[ -n "$dsn" ]] || { log "서버 $REMOTE_APP_ENV 에 DATABASE_URL이 없습니다 (먼저 BACKTEST_MODE=local ./deploy/deploy.sh)."; return 1; }
  "$BACKTEST_DIR/.venv/bin/python" - "$dsn" "$LOCAL_DB_PORT" <<'PY'
import sys
from urllib.parse import urlsplit, urlunsplit

dsn, local_port = sys.argv[1], sys.argv[2]
parts = urlsplit(dsn)
host, port = parts.hostname or "127.0.0.1", parts.port or 5432
auth = parts.netloc.rsplit("@", 1)[0] + "@" if "@" in parts.netloc else ""
local = urlunsplit((parts.scheme, f"{auth}127.0.0.1:{local_port}", parts.path, parts.query, parts.fragment))
print(host, port, local)
PY
}

# 이전 연결이 비정상 종료되면 서버 sshd가 127.0.0.1:REMOTE_API_PORT를 한동안 붙잡고 있다. 그 sshd 세션만 정리한다.
free_remote_port() {
  local out rc=0
  out="$(remote "line=\$(sudo -n ss -ltnpH 'sport = :$REMOTE_API_PORT' | head -n 1)
    [ -z \"\$line\" ] && exit 0
    case \"\$line\" in
      *'\"sshd'*)
        pid=\$(printf '%s' \"\$line\" | sed -nE 's/.*\"sshd[^\"]*\",pid=([0-9]+).*/\\1/p')
        [ -n \"\$pid\" ] && sudo -n kill \"\$pid\" && sleep 1
        exit 0 ;;
      *) printf '%s' \"\$line\"; exit 3 ;;
    esac")" || rc=$?
  if [[ $rc -eq 3 ]]; then
    log "서버 127.0.0.1:$REMOTE_API_PORT 를 다른 프로그램이 사용 중: $out"
    log "서버를 BACKTEST_MODE=local 로 배포했는지 확인하세요 (BACKTEST_MODE=local ./deploy/deploy.sh)."
  fi
  return $rc
}

check_local_prereqs() {
  command -v docker >/dev/null 2>&1 || die "Docker가 필요합니다."
  docker info >/dev/null 2>&1 || die "Docker 데몬이 동작하지 않습니다."
  docker image inspect "$LEAN_IMAGE" >/dev/null 2>&1 || die "LEAN 이미지가 없습니다: docker pull $LEAN_IMAGE"
  if [[ ! -x "$BACKTEST_DIR/.venv/bin/python" ]]; then
    log "backtester Python 의존성 설치 (uv sync)"
    (cd "$BACKTEST_DIR" && uv sync --quiet)
  fi
  if [[ ! -f "$BACKTEST_DIR/.lean-workspace/data/market-hours/market-hours-database.json" ]]; then
    log "LEAN 데이터 준비 (setup_lean_data.sh)"
    LEAN_SKIP_PULL=1 bash "$BACKTEST_DIR/scripts/setup_lean_data.sh"
  fi
  if (exec 3<>"/dev/tcp/127.0.0.1/$LOCAL_API_PORT") 2>/dev/null; then
    die "로컬 127.0.0.1:$LOCAL_API_PORT 를 이미 다른 프로그램이 쓰고 있습니다 (LOCAL_API_PORT=다른포트)."
  fi
}

run_worker() {
  prepare_key
  ssh_opts
  check_local_prereqs

  local db_host db_port local_dsn
  until read -r db_host db_port local_dsn < <(resolve_db); do
    log "서버에서 DB 정보를 읽지 못했습니다. 30초 후 다시 시도합니다."
    sleep 30
  done
  log "DB: 서버 $db_host:$db_port ⇐ 로컬 127.0.0.1:$LOCAL_DB_PORT"

  local api_pid tunnel_pid
  (
    cd "$BACKTEST_DIR"
    # backtester/.env의 DATABASE_URL(로컬 개발용)보다 이 값이 우선한다 (load_dotenv는 기존 환경변수를 덮어쓰지 않음).
    export DATABASE_URL="$local_dsn" PYTHONUNBUFFERED=1
    exec "$BACKTEST_DIR/.venv/bin/python" -m uvicorn backend.main:app --host 127.0.0.1 --port "$LOCAL_API_PORT"
  ) &
  api_pid=$!
  log "백테스트 API 시작: 127.0.0.1:$LOCAL_API_PORT (pid $api_pid)"

  (
    while :; do
      if free_remote_port; then
        log "SSH 터널 연결: 서버 127.0.0.1:$REMOTE_API_PORT → 로컬 :$LOCAL_API_PORT, 로컬 :$LOCAL_DB_PORT → 서버 $db_host:$db_port"
        ssh "${SSH_OPTS[@]}" -N -o ExitOnForwardFailure=yes \
          -R "127.0.0.1:$REMOTE_API_PORT:127.0.0.1:$LOCAL_API_PORT" \
          -L "127.0.0.1:$LOCAL_DB_PORT:$db_host:$db_port" \
          "$SSH_USER@$DEPLOY_HOST" || log "SSH 터널 종료 (exit $?)"
      fi
      sleep 5
    done
  ) &
  tunnel_pid=$!

  trap 'pkill -P "$tunnel_pid" 2>/dev/null || true; kill "$api_pid" "$tunnel_pid" 2>/dev/null || true; exit 0' INT TERM
  local rc=0
  wait -n "$api_pid" "$tunnel_pid" || rc=$?
  log "하위 프로세스 종료 (exit $rc) — 정리 후 종료합니다 (서비스면 자동 재시작)."
  pkill -P "$tunnel_pid" 2>/dev/null || true
  kill "$api_pid" "$tunnel_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  exit 1
}

install_service() {
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1 \
    || die "systemd 사용자 서비스를 쓸 수 없습니다. '$0 run' 을 터미널에서 직접 실행하세요."
  # 설치 전에 키·Docker·LEAN·의존성을 확인해 둔다.
  prepare_key
  check_local_prereqs

  local env_lines="" var
  for var in DEPLOY_HOST SSH_KEY KEY_DIR SSH_USER SSH_PORT LOCAL_API_PORT REMOTE_API_PORT LOCAL_DB_PORT; do
    [[ -n "${!var:-}" ]] && env_lines+="Environment=$var=${!var}"$'\n'
  done
  mkdir -p "$(dirname "$UNIT_FILE")"
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=LIMSON 백테스트 로컬 워커 (LEAN + SSH 터널 → $DEPLOY_HOST)
After=network-online.target

[Service]
Type=simple
ExecStart=$ROOT_DIR/deploy/local_backtest_worker.sh run
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
${env_lines}Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "$SERVICE_NAME"
  # 로그인 세션이 없어도(WSL이 백그라운드로 켜졌을 때) 사용자 서비스가 돌도록 한다.
  loginctl enable-linger "$USER" 2>/dev/null || log "참고: loginctl enable-linger 실패 — WSL 터미널이 열려 있을 때만 동작할 수 있습니다."
  log "설치 완료: $UNIT_FILE"
  sleep 8
  show_status
}

show_status() {
  if command -v systemctl >/dev/null 2>&1; then
    printf '서비스  : %s\n' "$(systemctl --user is-active "$SERVICE_NAME" 2>/dev/null || true)"
  fi
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$LOCAL_API_PORT/api/health" || true)"
  printf '로컬 API: http://127.0.0.1:%s/api/health → HTTP %s\n' "$LOCAL_API_PORT" "${code:-000}"
  prepare_key
  ssh_opts
  code="$(remote "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:$REMOTE_API_PORT/api/health" 2>/dev/null || true)"
  printf '서버 터널: %s 127.0.0.1:%s/api/health → HTTP %s\n' "$DEPLOY_HOST" "$REMOTE_API_PORT" "${code:-000}"
}

case "${1:-}" in
  run) run_worker ;;
  install) install_service ;;
  status) show_status ;;
  logs) exec journalctl --user -u "$SERVICE_NAME" -f -n 100 ;;
  restart) systemctl --user restart "$SERVICE_NAME" && sleep 8 && show_status ;;
  uninstall)
    systemctl --user disable --now "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$UNIT_FILE"
    systemctl --user daemon-reload
    log "삭제 완료"
    ;;
  *)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
