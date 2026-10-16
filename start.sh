#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STRATEGY_DIR="$ROOT_DIR/strategy_builder"
BACKTEST_DIR="$ROOT_DIR/backtester"
STRATEGY_FRONTEND_DIR="$STRATEGY_DIR/frontend"
BACKTEST_FRONTEND_DIR="$BACKTEST_DIR/frontend"
LEAN_PROJECTS_DIR="$BACKTEST_DIR/.lean-workspace/projects"
BACKTESTER_URL="${NEXT_PUBLIC_BACKTESTER_URL:-http://localhost:3001/backtest}"
STRATEGY_BUILDER_URL="${NEXT_PUBLIC_STRATEGY_BUILDER_URL:-http://localhost:3000/builder}"

declare -a SERVICE_PIDS=()
CLEANING_UP=false

stop_port_listener() {
  local port="$1"
  local pids attempt pid

  pids="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
  [[ -n "$pids" ]] || return 0

  echo "[준비] 포트 $port 기존 프로세스 종료"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
  done <<< "$pids"

  for attempt in {1..10}; do
    pids="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
    [[ -n "$pids" ]] || return 0
    sleep 0.2
  done

  pids="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null || true
  done <<< "$pids"
}

cleanup_project_lean_containers() {
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0

  local ids id label mounts source owned
  ids="$(docker ps -aq 2>/dev/null || true)"
  [[ -n "$ids" ]] || return 0

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue

    label="$(docker inspect -f '{{ index .Config.Labels "com.open-trading-api.component" }}' "$id" 2>/dev/null || true)"
    mounts="$(docker inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' "$id" 2>/dev/null || true)"
    owned=false

    if [[ "$label" == "backtester-lean" ]]; then
      owned=true
    fi

    while IFS= read -r source; do
      if [[ "$source" == "$LEAN_PROJECTS_DIR/"* ]]; then
        owned=true
      fi
    done <<< "$mounts"

    if [[ "$owned" == true ]]; then
      echo "[Docker] 프로젝트 LEAN 컨테이너 정리: $id"
      docker rm -f "$id" >/dev/null 2>&1 || true
    fi
  done <<< "$ids"
}

cleanup() {
  [[ "$CLEANING_UP" == false ]] || return 0
  CLEANING_UP=true
  trap - EXIT INT TERM

  echo
  echo "[종료] 백엔드와 프론트엔드를 종료합니다."
  local pid
  for pid in "${SERVICE_PIDS[@]}"; do
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${SERVICE_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  cleanup_project_lean_containers
  echo "[완료] 프로젝트 서비스가 종료되었습니다. PostgreSQL 및 Docker Desktop은 유지됩니다."
}

start_group() {
  local label="$1"
  local workdir="$2"
  shift 2

  echo "[$label] 시작"
  setsid bash -c 'cd "$1" || exit 1; shift; exec "$@"' _ "$workdir" "$@" &
  local pid=$!
  SERVICE_PIDS+=("$pid")
}

wait_for_http() {
  local url="$1"
  local label="$2"
  local attempt status

  # lsof의 포트 감지 결과 대신 실제 HTTP 응답으로 서비스 준비 여부를 판단한다.
  for attempt in {1..60}; do
    status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null || true)"
    case "$status" in
      2??|3??)
        echo "[$label] 준비 완료: $url (HTTP $status)"
        return 0
        ;;
    esac
    sleep 1
  done

  echo "[$label] 60초 안에 HTTP 응답을 받지 못했습니다: $url (마지막 상태: ${status:-연결 실패})" >&2
  return 1
}

if ! command -v lsof >/dev/null 2>&1; then
  echo "lsof가 필요합니다. WSL에서 'sudo apt install lsof'를 실행하세요." >&2
  exit 1
fi
if ! command -v setsid >/dev/null 2>&1; then
  echo "setsid 명령을 찾을 수 없습니다. WSL Ubuntu 환경을 확인하세요." >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "Docker Desktop이 실행 중인지 확인한 뒤 다시 실행하세요." >&2
  exit 1
fi
if ! command -v uv >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "uv와 Node.js/npm이 WSL Ubuntu 안에 설치되어 있어야 합니다." >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "curl이 필요합니다. WSL에서 'sudo apt install curl'을 실행하세요." >&2
  exit 1
fi

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "=================================================="
echo " Strategy Builder + Backtester"
echo " 전략 빌더: $STRATEGY_BUILDER_URL"
echo " 백테스트:  $BACKTESTER_URL"
echo " 종료: Ctrl+C"
echo "=================================================="

SYMBOL_PROPS="$BACKTEST_DIR/.lean-workspace/data/symbol-properties/symbol-properties-database.csv"
MARKET_HOURS="$BACKTEST_DIR/.lean-workspace/data/market-hours/market-hours-database.json"
if [[ ! -f "$SYMBOL_PROPS" || ! -f "$MARKET_HOURS" ]]; then
  echo "[LEAN] 필수 데이터 파일을 확인하고 설정합니다."
  bash "$BACKTEST_DIR/scripts/setup_lean_data.sh"
fi

for frontend_dir in "$STRATEGY_FRONTEND_DIR" "$BACKTEST_FRONTEND_DIR"; do
  if [[ ! -d "$frontend_dir/node_modules" ]]; then
    echo "[Frontend] 의존성 설치: $frontend_dir"
    (cd "$frontend_dir" && npm install)
  fi
done

# 기존 각 앱의 start.sh와 동일하게 앱 전용 포트의 기존 리스너를 교체한다.
for port in 3000 3001 8000 8002; do
  stop_port_listener "$port"
done

# 이전 실행이 중단되면서 남은 LEAN 컨테이너도 프로젝트 경로를 확인해 정리한다.
cleanup_project_lean_containers

start_group "전략 빌더 BE :8000" "$STRATEGY_DIR" uv run python -m uvicorn backend.main:app --host 127.0.0.1 --port 8000
start_group "백테스트 BE :8002" "$BACKTEST_DIR" uv run uvicorn backend.main:app --host 127.0.0.1 --port 8002
start_group "전략 빌더 FE :3000" "$STRATEGY_FRONTEND_DIR" env "NEXT_PUBLIC_BACKTESTER_URL=$BACKTESTER_URL" npm run dev
start_group "백테스트 FE :3001" "$BACKTEST_FRONTEND_DIR" env "NEXT_PUBLIC_STRATEGY_BUILDER_URL=$STRATEGY_BUILDER_URL" npm run dev

wait_for_http "http://127.0.0.1:8000/docs" "전략 빌더 BE"
wait_for_http "http://127.0.0.1:8002/docs" "백테스트 BE"
wait_for_http "http://127.0.0.1:3000/builder" "전략 빌더 FE"
wait_for_http "http://127.0.0.1:3001/backtest" "백테스트 FE"

echo
echo "모든 서비스가 실행되었습니다."
echo "  전략 빌더: $STRATEGY_BUILDER_URL"
echo "  백테스트:  $BACKTESTER_URL"
echo "Ctrl+C를 누르면 네 서비스와 이 프로젝트의 LEAN 컨테이너가 종료됩니다."

set +e
wait -n "${SERVICE_PIDS[@]}"
status=$?
set -e
echo "[경고] 서비스 프로세스 하나가 종료되었습니다. 나머지 서비스도 정리합니다."
exit "$status"
