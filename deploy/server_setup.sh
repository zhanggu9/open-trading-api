#!/usr/bin/env bash
# 서버(EC2 VM)에서 실행하는 설치/배포 스크립트.
# deploy/deploy.sh가 소스를 올린 뒤 SSH로 호출하며, 서버에서 직접 다시 실행해도 된다(멱등).
#
#   bash ~/open-trading-api/deploy/server_setup.sh
#
# 순서: 시스템 패키지(nginx, Docker) → Node.js/uv → Python 의존성 → 프론트엔드 빌드
#       → PostgreSQL 연결 확인 → LEAN 이미지/데이터 → systemd 서비스 → nginx(:WEB_PORT) → 헬스체크
#
# 환경변수(모두 선택):
#   WEB_PORT=8010              외부 공개 포트
#   PUBLIC_HOST=13.209.87.155  안내 메시지에 표시할 주소
#   DATABASE_URL=...           비우면 서버의 PostgreSQL(Docker 컨테이너/로컬 포트)을 자동으로 찾는다
#   BASIC_AUTH=on|off          웹 접속 Basic 인증 (기본 on — 주문/계좌 API가 함께 노출되기 때문)
#   BASIC_AUTH_USER=admin
#   BASIC_AUTH_PASSWORD=...    비우면 기존 비밀번호 유지, 최초 배포 시 무작위 생성
#   SKIP_LEAN_PULL=1           quantconnect/lean 이미지 다운로드 생략
#   FORCE_LEAN_PULL=1          디스크 여유 검사를 무시하고 LEAN 이미지 다운로드
#   LEAN_MIN_FREE_GB=50        LEAN 이미지를 받기 위해 필요한 최소 디스크 여유(GB)
#   CREATE_SWAP=0              메모리가 작을 때 스왑 파일(2GB) 자동 생성 끄기
set -Eeuo pipefail

if [[ "${1:-}" == "--env-file" && -n "${2:-}" ]]; then
  # deploy.sh가 비밀번호 등을 명령줄(ps에 노출) 대신 파일로 넘긴다.
  set -a
  # shellcheck disable=SC1090
  source "$2"
  set +a
  rm -f -- "$2"
fi

APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="$APP_DIR/deploy"
WEB_PORT="${WEB_PORT:-8010}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
BASIC_AUTH="${BASIC_AUTH:-on}"
BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"
BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-}"
SKIP_LEAN_PULL="${SKIP_LEAN_PULL:-0}"
FORCE_LEAN_PULL="${FORCE_LEAN_PULL:-0}"
CREATE_SWAP="${CREATE_SWAP:-1}"
NODE_MAJOR="${NODE_MAJOR:-22}"

SERVICE_USER="$(id -un)"
SERVICE_GROUP="$(id -gn)"
CONFIG_DIR="/etc/open-trading-api"
APP_ENV_FILE="$CONFIG_DIR/app.env"
NGINX_CONF="/etc/nginx/conf.d/open-trading-api.conf"
HTPASSWD_FILE="/etc/nginx/open-trading-api.htpasswd"
CREDENTIALS_FILE="$HOME/.open-trading-api-web-credentials"
LEAN_IMAGE="quantconnect/lean:latest"
SERVICES=(open-trading-strategy-api open-trading-backtest-api open-trading-strategy-web open-trading-backtest-web)
WEB_SERVICES=(open-trading-strategy-web open-trading-backtest-web)

WARNINGS=()
DB_STATUS="확인 안 됨"
LEAN_STATUS="확인 안 됨"
AUTH_NOTE=""
NODE_BIN_DIR=""
UV_BIN=""
CURRENT_STEP="시작"

log() { CURRENT_STEP="$*"; printf '\n\033[1;34m[setup]\033[0m %s\n' "$*"; }
info() { printf '        %s\n' "$*"; }
# SSH로 실행되면 stdout/stderr 순서가 섞이므로 경고도 stdout으로 낸다.
warn() { printf '\033[1;33m[경고]\033[0m %s\n' "$*"; WARNINGS+=("$*"); }
die() { printf '\033[1;31m[실패]\033[0m %s\n' "$*" >&2; exit 1; }
on_exit() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    printf '\n\033[1;31m[중단]\033[0m "%s" 단계에서 실패했습니다 (exit %d). 위 로그를 확인한 뒤 다시 실행하세요.\n' \
      "$CURRENT_STEP" "$rc" >&2
  fi
}
trap on_exit EXIT

as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

mask_dsn() { sed -E 's#(://[^:/@]+:)[^@]*@#\1****@#' <<<"$1"; }

port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# ---------------------------------------------------------------------------
# 1. 시스템 패키지
# ---------------------------------------------------------------------------
PKG=""
if command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf >/dev/null 2>&1; then PKG=dnf
elif command -v yum >/dev/null 2>&1; then PKG=yum
fi
APT_UPDATED=0

pkg_install() {
  case "$PKG" in
    apt)
      if [[ $APT_UPDATED -eq 0 ]]; then
        as_root env DEBIAN_FRONTEND=noninteractive apt-get update -q
        APT_UPDATED=1
      fi
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@"
      ;;
    dnf|yum) as_root "$PKG" install -y -q "$@" ;;
    *) die "패키지 관리자(apt/dnf/yum)를 찾지 못했습니다. 직접 설치하세요: $*" ;;
  esac
}

nginx_bin() { command -v nginx 2>/dev/null || echo /usr/sbin/nginx; }

install_system_packages() {
  log "시스템 패키지 확인"
  if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
    info "sudo 권한이 필요합니다."
    sudo -v || die "sudo 권한이 없습니다."
  fi

  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  command -v gzip >/dev/null 2>&1 || missing+=(gzip)
  if [[ ${#missing[@]} -gt 0 ]]; then
    info "설치: ${missing[*]}"
    pkg_install "${missing[@]}"
  fi

  if [[ ! -x "$(nginx_bin)" ]]; then
    info "설치: nginx"
    if [[ "$PKG" == "apt" ]] && port_in_use 80 && [[ ! -e /usr/sbin/policy-rc.d ]]; then
      # 80 포트를 다른 프로그램이 쓰고 있으면 기본 사이트 때문에 설치 직후 자동 시작이 실패한다.
      # 설치 중 자동 시작을 막고 기본 사이트를 끈 뒤 이 스크립트가 직접 시작한다.
      printf '#!/bin/sh\nexit 101\n' | as_root tee /usr/sbin/policy-rc.d >/dev/null
      as_root chmod 755 /usr/sbin/policy-rc.d
      pkg_install nginx || { as_root rm -f /usr/sbin/policy-rc.d; die "nginx 설치 실패"; }
      as_root rm -f /usr/sbin/policy-rc.d /etc/nginx/sites-enabled/default
    else
      pkg_install nginx
    fi
  fi
  [[ -x "$(nginx_bin)" ]] || die "nginx 설치에 실패했습니다."
}

ensure_docker() {
  log "Docker 확인 (LEAN 백테스트 엔진 실행용)"
  if ! command -v docker >/dev/null 2>&1; then
    info "Docker 설치"
    case "$PKG" in
      apt) pkg_install docker.io ;;
      dnf|yum) pkg_install docker ;;
      *) warn "Docker를 자동 설치할 수 없습니다. 백테스트 실행에 Docker가 필요합니다."; return 0 ;;
    esac || { warn "Docker 설치 실패: 백테스트를 실행할 수 없습니다."; return 0; }
  fi
  if ! as_root docker info >/dev/null 2>&1; then
    as_root systemctl enable --now docker >/dev/null 2>&1 || true
  fi
  if ! as_root docker info >/dev/null 2>&1; then
    warn "Docker 데몬이 동작하지 않습니다: 백테스트를 실행할 수 없습니다."
    return 0
  fi
  # 백테스트 API(systemd, User=$SERVICE_USER)가 docker 명령을 쓸 수 있게 한다.
  if getent group docker >/dev/null 2>&1; then
    if ! id -nG "$SERVICE_USER" | tr ' ' '\n' | grep -qx docker; then
      as_root usermod -aG docker "$SERVICE_USER"
      info "$SERVICE_USER 사용자를 docker 그룹에 추가했습니다."
    fi
  else
    warn "docker 그룹이 없어 $SERVICE_USER 사용자가 Docker를 쓰지 못할 수 있습니다."
  fi
  info "Docker $(as_root docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') 동작 중"
}

ensure_swap() {
  [[ "$CREATE_SWAP" == "1" ]] || return 0
  local mem_kb swap_kb avail_kb
  mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
  # Next.js 빌드 두 번 + LEAN 컨테이너를 감당하려면 메모리+스왑이 3GB는 되는 편이 안전하다.
  if (( mem_kb + swap_kb >= 3 * 1024 * 1024 )) || [[ -e /swapfile ]]; then
    return 0
  fi
  avail_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
  if (( avail_kb < 6 * 1024 * 1024 )); then
    warn "메모리가 작지만 디스크 여유도 부족해 스왑을 만들지 않았습니다 (빌드가 메모리 부족으로 실패할 수 있음)."
    return 0
  fi
  log "메모리 $((mem_kb / 1024))MB → 2GB 스왑 파일(/swapfile) 생성"
  if as_root fallocate -l 2G /swapfile 2>/dev/null || as_root dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none; then
    as_root chmod 600 /swapfile
    if as_root mkswap /swapfile >/dev/null && as_root swapon /swapfile; then
      grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | as_root tee -a /etc/fstab >/dev/null
      return 0
    fi
  fi
  as_root rm -f /swapfile
  warn "스왑 파일 생성 실패 (빌드가 메모리 부족으로 실패할 수 있음)."
}

# ---------------------------------------------------------------------------
# 2. Node.js / uv
# ---------------------------------------------------------------------------
ensure_node() {
  log "Node.js 확인 (Next.js 16은 20.9 이상 필요)"
  local candidate dir version
  for candidate in "$(command -v node 2>/dev/null || true)" /opt/node/bin/node /usr/local/bin/node /usr/bin/node; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    dir="$(dirname "$candidate")"
    [[ -x "$dir/npm" ]] || continue
    version="$("$candidate" -p 'process.versions.node' 2>/dev/null || echo 0.0.0)"
    if "$candidate" -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>20||(a===20&&b>=9)?0:1)' 2>/dev/null; then
      NODE_BIN_DIR="$dir"
      info "사용: $candidate (v$version)"
      return 0
    fi
  done

  local arch base line sha file tmp
  case "$(uname -m)" in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "지원하지 않는 CPU 아키텍처: $(uname -m)" ;;
  esac
  base="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x"
  line="$(curl -fsSL "$base/SHASUMS256.txt" | grep -E "  node-v[0-9.]+-linux-${arch}\.tar\.gz$" | head -n 1 || true)"
  [[ -n "$line" ]] || die "Node.js 다운로드 목록을 가져오지 못했습니다: $base"
  sha="${line%%  *}"
  file="${line##*  }"
  info "설치: $file → /opt/node"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/$file" "$base/$file"
  (cd "$tmp" && printf '%s  %s\n' "$sha" "$file" | sha256sum -c - >/dev/null) || die "Node.js 체크섬 불일치"
  as_root rm -rf /opt/node.new
  as_root mkdir -p /opt/node.new
  as_root tar -xzf "$tmp/$file" -C /opt/node.new --strip-components=1
  as_root rm -rf /opt/node
  as_root mv /opt/node.new /opt/node
  rm -rf "$tmp"
  NODE_BIN_DIR=/opt/node/bin
  info "설치 완료: $("$NODE_BIN_DIR/node" -v)"
}

ensure_uv() {
  log "uv 확인 (Python 패키지 관리자)"
  UV_BIN="$(command -v uv 2>/dev/null || true)"
  [[ -n "$UV_BIN" ]] || { [[ -x "$HOME/.local/bin/uv" ]] && UV_BIN="$HOME/.local/bin/uv"; } || true
  [[ -n "$UV_BIN" ]] || { [[ -x "$HOME/.cargo/bin/uv" ]] && UV_BIN="$HOME/.cargo/bin/uv"; } || true
  if [[ -z "$UV_BIN" ]]; then
    info "uv 설치"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    UV_BIN="$HOME/.local/bin/uv"
  fi
  [[ -x "$UV_BIN" ]] || die "uv를 찾을 수 없습니다."
  info "사용: $UV_BIN ($("$UV_BIN" --version))"
}

# ---------------------------------------------------------------------------
# 3. 애플리케이션 빌드
# ---------------------------------------------------------------------------
install_python_deps() {
  log "Python 의존성 설치 (uv sync)"
  local project
  for project in strategy_builder backtester; do
    info "$project"
    (cd "$APP_DIR/$project" && "$UV_BIN" sync --quiet)
  done
}

write_frontend_env() {
  # 단일 포트 배포용 경로. nginx 라우팅(deploy/nginx)과 짝을 이룬다.
  cat > "$APP_DIR/strategy_builder/frontend/.env.production.local" <<'EOF'
# deploy/server_setup.sh가 생성 — 단일 포트(nginx) 배포용
NEXT_PUBLIC_BACKTESTER_URL=/backtest
EOF
  cat > "$APP_DIR/backtester/frontend/.env.production.local" <<'EOF'
# deploy/server_setup.sh가 생성 — 단일 포트(nginx) 배포용
NEXT_PUBLIC_API_URL=/backtest
NEXT_PUBLIC_STRATEGY_BUILDER_URL=/builder
ASSET_PREFIX=/backtest-static
EOF
}

build_frontends() {
  log "프론트엔드 빌드 (npm ci + next build)"
  write_frontend_env
  # 빌드 중에는 .next가 지워지므로 실행 중인 웹 서비스를 먼저 멈춘다.
  local svc
  for svc in "${WEB_SERVICES[@]}"; do
    as_root systemctl stop "$svc" >/dev/null 2>&1 || true
  done

  local dir lock_hash stamp
  for dir in "$APP_DIR/strategy_builder/frontend" "$APP_DIR/backtester/frontend"; do
    info "${dir#"$APP_DIR"/}"
    lock_hash="$(sha256sum "$dir/package-lock.json" | cut -d' ' -f1)"
    stamp="$dir/node_modules/.deploy-lock-sha256"
    if [[ ! -f "$stamp" || "$(cat "$stamp")" != "$lock_hash" ]]; then
      (cd "$dir" && PATH="$NODE_BIN_DIR:$PATH" "$NODE_BIN_DIR/npm" ci --no-audit --no-fund --loglevel=error)
      echo "$lock_hash" > "$stamp"
    fi
    (cd "$dir" && PATH="$NODE_BIN_DIR:$PATH" NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 \
      "$NODE_BIN_DIR/node" node_modules/next/dist/bin/next build)
  done
}

# ---------------------------------------------------------------------------
# 4. PostgreSQL
# ---------------------------------------------------------------------------
dotenv_value() {  # backtester/.env에서 마지막으로 지정된 값을 읽는다
  { sed -n "s/^$1=//p" "$APP_DIR/backtester/.env" 2>/dev/null || true; } | tail -n 1 | tr -d '\r'
}

build_dsn() {  # user password host port dbname → URL 인코딩된 DSN
  "$APP_DIR/backtester/.venv/bin/python" - "$@" <<'PY'
import sys
from urllib.parse import quote

user, password, host, port, dbname = sys.argv[1:6]
auth = quote(user, safe="") + (":" + quote(password, safe="") if password else "")
print(f"postgresql://{auth}@{host}:{port}/{quote(dbname, safe='')}")
PY
}

db_probe() {  # DSN 테이블 → "OK <행 수>" | "NO_TABLE <메시지>" | "FAIL <메시지>" 한 줄
  "$APP_DIR/backtester/.venv/bin/python" - "$1" "$2" <<'PY' 2>&1 | tail -n 1 || true
import sys

import psycopg
from psycopg import sql

dsn, table = sys.argv[1], sys.argv[2]
try:
    with psycopg.connect(dsn, connect_timeout=5) as conn, conn.cursor() as cur:
        cur.execute("SELECT to_regclass(%s)", (table,))
        if cur.fetchone()[0] is None:
            print(f"NO_TABLE 테이블 없음: {table}")
        else:
            cur.execute(sql.SQL("SELECT count(*) FROM {}").format(sql.Identifier(*table.split("."))))
            print(f"OK {cur.fetchone()[0]}")
except (psycopg.Error, ValueError) as exc:
    lines = str(exc).strip().splitlines()
    print(f"FAIL {type(exc).__name__}: {lines[0] if lines else ''}")
PY
}

collect_dsn_candidates() {
  local current repo_url repo_user repo_pass repo_db port
  [[ -n "${DATABASE_URL:-}" ]] && echo "$DATABASE_URL"
  current="$(as_root sed -n 's/^DATABASE_URL=//p' "$APP_ENV_FILE" 2>/dev/null | tail -n 1 || true)"
  [[ -n "$current" ]] && echo "$current"
  repo_url="$(dotenv_value DATABASE_URL)"
  [[ -n "$repo_url" ]] && echo "$repo_url"

  # 서버에서 Docker로 띄운 PostgreSQL: 컨테이너 환경변수에서 계정을, 포트 매핑/컨테이너 IP에서 주소를 얻는다.
  if as_root docker info >/dev/null 2>&1; then
    local id image envs user pass db ip
    while read -r id image; do
      [[ "$image" =~ (postgres|postgis|timescale) ]] || continue
      envs="$(as_root docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$id" 2>/dev/null || true)"
      user="$(sed -n 's/^POSTGRES_USER=//p' <<<"$envs" | tail -n 1)"; user="${user:-postgres}"
      pass="$(sed -n 's/^POSTGRES_PASSWORD=//p' <<<"$envs" | tail -n 1)"
      db="$(sed -n 's/^POSTGRES_DB=//p' <<<"$envs" | tail -n 1)"; db="${db:-$user}"
      for port in $(as_root docker port "$id" 5432/tcp 2>/dev/null | sed -nE 's/.*:([0-9]+)$/\1/p' | sort -u); do
        build_dsn "$user" "$pass" 127.0.0.1 "$port" "$db"
      done
      for ip in $(as_root docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$id" 2>/dev/null); do
        build_dsn "$user" "$pass" "$ip" 5432 "$db"
      done
    done < <(as_root docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null || true)
  fi

  # 저장소 .env의 계정으로 흔한 로컬 포트도 시도한다.
  if [[ "$repo_url" =~ ^postgres(ql)?://([^:@/]+)(:([^@]*))?@[^/]+/([^?]+) ]]; then
    repo_user="${BASH_REMATCH[2]}"; repo_pass="${BASH_REMATCH[4]}"; repo_db="${BASH_REMATCH[5]}"
    for port in 55432 5432; do
      echo "postgresql://$repo_user${repo_pass:+:$repo_pass}@127.0.0.1:$port/$repo_db"
    done
  fi
}

configure_database() {
  log "PostgreSQL 연결 확인"
  local table chosen="" fallback="" candidate result status
  table="$(dotenv_value PG_OHLCV_TABLE)"; table="${table:-public.ohlcv}"

  local -a candidates=()
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    [[ " ${candidates[*]-} " == *" $candidate "* ]] || candidates+=("$candidate")
  done < <(collect_dsn_candidates)

  for candidate in "${candidates[@]+"${candidates[@]}"}"; do
    result="$(db_probe "$candidate" "$table")"
    status="${result%% *}"
    result="${result#* }"
    case "$status" in
      OK)
        info "OK   $(mask_dsn "$candidate") — $table ${result}행"
        chosen="$candidate"
        DB_STATUS="정상 ($(mask_dsn "$candidate"), $table ${result}행)"
        break
        ;;
      NO_TABLE)
        info "연결됨, $result: $(mask_dsn "$candidate")"
        [[ -n "$fallback" ]] || fallback="$candidate"
        ;;
      *)
        info "실패 $(mask_dsn "$candidate") — $result"
        ;;
    esac
    # 사용자가 지정한 주소는 다른 후보로 바꾸지 않는다.
    if [[ -n "${DATABASE_URL:-}" ]]; then break; fi
  done

  if [[ -z "$chosen" && -n "$fallback" ]]; then
    chosen="$fallback"
    DB_STATUS="연결됨, $table 테이블 없음 ($(mask_dsn "$fallback"))"
    warn "PostgreSQL에 $table 테이블이 없습니다. 백테스트 데이터 조회가 실패합니다."
  fi
  if [[ -z "$chosen" ]]; then
    chosen="${DATABASE_URL:-${candidates[0]:-}}"
    DB_STATUS="연결 실패"
    warn "PostgreSQL에 연결하지 못했습니다. DATABASE_URL=postgresql://사용자:비밀번호@호스트:포트/DB 로 지정해 다시 배포하세요."
  fi

  as_root mkdir -p "$CONFIG_DIR"
  {
    echo "# deploy/server_setup.sh가 관리하는 서버 전용 설정 (backtester/.env보다 우선)"
    if [[ -n "$chosen" ]]; then echo "DATABASE_URL=$chosen"; fi
  } | as_root tee "$APP_ENV_FILE" >/dev/null
  as_root chmod 600 "$APP_ENV_FILE"
}

# ---------------------------------------------------------------------------
# 5. LEAN (백테스트 엔진)
# ---------------------------------------------------------------------------
setup_lean() {
  log "LEAN 백테스트 엔진 준비"
  if ! as_root docker info >/dev/null 2>&1; then
    LEAN_STATUS="Docker 없음 — 백테스트 불가"
    return 0
  fi

  if as_root docker image inspect "$LEAN_IMAGE" >/dev/null 2>&1; then
    LEAN_STATUS="이미지 준비됨 ($LEAN_IMAGE)"
  elif [[ "$SKIP_LEAN_PULL" == "1" ]]; then
    LEAN_STATUS="이미지 없음 (SKIP_LEAN_PULL=1) — 백테스트 불가"
    warn "LEAN 이미지를 받지 않았습니다. 백테스트 전에 'sudo docker pull $LEAN_IMAGE' 필요."
  else
    local docker_root free_gb need_gb
    docker_root="$(as_root docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
    free_gb="$(as_root df -Pk "$docker_root" 2>/dev/null | awk 'NR==2 {print int($4 / 1024 / 1024)}' || true)"
    free_gb="${free_gb:-0}"
    # quantconnect/lean:latest는 압축 기준 amd64 약 14GB, arm64 약 5GB(풀면 몇 배)다.
    case "$(uname -m)" in aarch64|arm64) need_gb=20 ;; *) need_gb=50 ;; esac
    need_gb="${LEAN_MIN_FREE_GB:-$need_gb}"
    if (( free_gb < need_gb )) && [[ "$FORCE_LEAN_PULL" != "1" ]]; then
      LEAN_STATUS="이미지 없음 (디스크 여유 ${free_gb}GB < ${need_gb}GB) — 백테스트 불가"
      warn "디스크 여유(${free_gb}GB)가 부족해 LEAN 이미지를 받지 않았습니다. EBS 볼륨을 늘린 뒤 다시 배포하거나 FORCE_LEAN_PULL=1로 강제하세요."
    else
      info "docker pull $LEAN_IMAGE (용량이 커서 수 분 이상 걸립니다, 디스크 여유 ${free_gb}GB)"
      if as_root docker pull "$LEAN_IMAGE"; then
        LEAN_STATUS="이미지 준비됨 ($LEAN_IMAGE)"
      else
        LEAN_STATUS="이미지 다운로드 실패 — 백테스트 불가"
        warn "LEAN 이미지 다운로드 실패. 'sudo docker pull $LEAN_IMAGE'를 다시 실행하세요."
      fi
    fi
  fi

  # 거래소 시간/심볼 속성/KRX 마스터 데이터. 이 세션에는 docker 그룹이 아직 반영되지 않았을 수 있다.
  local script="$APP_DIR/backtester/scripts/setup_lean_data.sh" ok=0
  if docker info >/dev/null 2>&1; then
    LEAN_SKIP_PULL=1 bash "$script" && ok=1
  else
    sg docker -c "LEAN_SKIP_PULL=1 bash $(printf '%q' "$script")" && ok=1
  fi
  if [[ $ok -eq 0 ]]; then
    warn "LEAN 데이터 준비(setup_lean_data.sh)가 실패했습니다."
    LEAN_STATUS="$LEAN_STATUS, 데이터 준비 실패"
  fi
}

# ---------------------------------------------------------------------------
# 6. 서비스 / nginx
# ---------------------------------------------------------------------------
render() {
  sed -e "s|@APP_DIR@|$APP_DIR|g" \
      -e "s|@SERVICE_USER@|$SERVICE_USER|g" \
      -e "s|@SERVICE_GROUP@|$SERVICE_GROUP|g" \
      -e "s|@NODE_BIN_DIR@|$NODE_BIN_DIR|g" \
      -e "s|@APP_ENV_FILE@|$APP_ENV_FILE|g" \
      -e "s|@WEB_PORT@|$WEB_PORT|g" \
      -e "s|@AUTH_BASIC@|$1|g" \
      "$2"
}

install_services() {
  log "systemd 서비스 등록/재시작"
  local svc
  for svc in "${SERVICES[@]}"; do
    render "" "$DEPLOY_DIR/systemd/$svc.service" | as_root tee "/etc/systemd/system/$svc.service" >/dev/null
  done
  as_root systemctl daemon-reload
  as_root systemctl enable "${SERVICES[@]}" >/dev/null 2>&1
  as_root systemctl restart "${SERVICES[@]}"
  info "${SERVICES[*]}"
}

write_htpasswd() {
  local hash group
  hash="$(openssl passwd -apr1 "$BASIC_AUTH_PASSWORD")"
  printf '%s:%s\n' "$BASIC_AUTH_USER" "$hash" | as_root tee "$HTPASSWD_FILE" >/dev/null
  group="$(awk '$1 == "user" {gsub(";", "", $2); print $2; exit}' /etc/nginx/nginx.conf 2>/dev/null || true)"
  group="${group:-www-data}"
  if as_root chgrp "$group" "$HTPASSWD_FILE" 2>/dev/null; then
    as_root chmod 640 "$HTPASSWD_FILE"
  else
    as_root chmod 644 "$HTPASSWD_FILE"
  fi
  ( umask 077; printf 'URL: http://%s:%s/\nID: %s\nPW: %s\n' "${PUBLIC_HOST:-<서버 주소>}" "$WEB_PORT" "$BASIC_AUTH_USER" "$BASIC_AUTH_PASSWORD" > "$CREDENTIALS_FILE" )
}

configure_basic_auth() {
  if [[ "$BASIC_AUTH" == "off" ]]; then
    AUTH_NOTE="Basic 인증 꺼짐 (BASIC_AUTH=off)"
    return 0
  fi
  if [[ -n "$BASIC_AUTH_PASSWORD" ]]; then
    write_htpasswd
    AUTH_NOTE="ID $BASIC_AUTH_USER / PW (배포 시 지정한 값)"
  elif as_root test -s "$HTPASSWD_FILE" && as_root grep -q "^$BASIC_AUTH_USER:" "$HTPASSWD_FILE"; then
    AUTH_NOTE="기존 계정 유지 (ID $BASIC_AUTH_USER, 비밀번호는 서버의 $CREDENTIALS_FILE)"
    BASIC_AUTH_PASSWORD="$(sed -n 's/^PW: //p' "$CREDENTIALS_FILE" 2>/dev/null || true)"
  else
    BASIC_AUTH_PASSWORD="$(openssl rand -hex 10)"
    write_htpasswd
    AUTH_NOTE="ID $BASIC_AUTH_USER / PW $BASIC_AUTH_PASSWORD (서버의 $CREDENTIALS_FILE에도 저장)"
  fi
}

configure_nginx() {
  log "nginx 설정 (:$WEB_PORT)"
  configure_basic_auth
  local realm='"LIMSON"'
  [[ "$BASIC_AUTH" == "off" ]] && realm=off
  if port_in_use "$WEB_PORT" && ! [[ -f "$NGINX_CONF" ]] && command -v ss >/dev/null 2>&1 \
     && ! as_root ss -ltnpH "sport = :$WEB_PORT" 2>/dev/null | grep -q nginx; then
    die "$WEB_PORT 포트를 다른 프로그램이 쓰고 있습니다: $(as_root ss -ltnpH "sport = :$WEB_PORT" 2>/dev/null | head -n 1). WEB_PORT를 바꾸거나 해당 프로그램을 멈추세요."
  fi
  render "$realm" "$DEPLOY_DIR/nginx/open-trading-api.conf.template" | as_root tee "$NGINX_CONF" >/dev/null
  # 우분투 기본 사이트(:80, [::]:80)는 80 포트 충돌이나 IPv6 비활성 환경에서 nginx 전체를 막는다.
  # 그런 경우에만 기본 사이트를 끈다.
  if ! as_root "$(nginx_bin)" -t -q 2>/dev/null && [[ -e /etc/nginx/sites-enabled/default ]]; then
    warn "nginx 설정 검사 실패 → 기본 사이트(/etc/nginx/sites-enabled/default)를 끄고 다시 시도합니다."
    as_root rm -f /etc/nginx/sites-enabled/default
  fi
  as_root "$(nginx_bin)" -t -q
  as_root systemctl enable nginx >/dev/null 2>&1 || true
  if as_root systemctl is-active --quiet nginx; then
    as_root systemctl reload nginx
  elif ! as_root systemctl restart nginx; then
    if [[ -e /etc/nginx/sites-enabled/default ]]; then
      warn "nginx 시작 실패 → 기본 사이트(/etc/nginx/sites-enabled/default, :80)를 끄고 다시 시도합니다."
      as_root rm -f /etc/nginx/sites-enabled/default
      as_root systemctl restart nginx
    else
      die "nginx를 시작하지 못했습니다 (sudo journalctl -u nginx -n 50)."
    fi
  fi

  if command -v ufw >/dev/null 2>&1 && as_root ufw status 2>/dev/null | grep -q "Status: active"; then
    as_root ufw allow "$WEB_PORT/tcp" >/dev/null
    info "ufw: $WEB_PORT/tcp 허용"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && as_root firewall-cmd --state >/dev/null 2>&1; then
    as_root firewall-cmd --permanent --add-port="$WEB_PORT/tcp" >/dev/null && as_root firewall-cmd --reload >/dev/null
    info "firewalld: $WEB_PORT/tcp 허용"
  fi
}

# ---------------------------------------------------------------------------
# 7. 헬스체크
# ---------------------------------------------------------------------------
CURL_AUTH_CONFIG=""  # curl -K 설정 파일: 비밀번호를 명령줄에 노출하지 않고 공백/특수문자도 그대로 넘긴다
http_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 -K "$CURL_AUTH_CONFIG" "$1" 2>/dev/null || true
}

wait_upstreams() {  # 막 재시작한 서비스들이 직접 응답할 때까지 최대 2분 기다린다
  local deadline=$((SECONDS + 120)) pending url
  local -a urls=(
    "http://127.0.0.1:8000/api/health"
    "http://127.0.0.1:8002/api/health"
    "http://127.0.0.1:3000/builder"
    "http://127.0.0.1:3001/backtest"
  )
  while :; do
    pending=()
    for url in "${urls[@]}"; do
      [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)" == "200" ]] || pending+=("$url")
    done
    [[ ${#pending[@]} -eq 0 ]] && return 0
    if (( SECONDS >= deadline )); then
      warn "2분 안에 응답하지 않은 서비스: ${pending[*]}"
      return 0
    fi
    sleep 2
  done
}

collect_symbol_masters() {
  # 종목명 조회/검색은 .master/ CSV를 쓴다. 새 서버에는 없으므로 처음 한 번 KIS 공개 마스터파일을 받아 둔다.
  log "종목 마스터(코스피/코스닥) 확인"
  local port total result
  for port in 8000 8002; do
    total="$(curl -s --max-time 10 "http://127.0.0.1:$port/api/symbols/status" 2>/dev/null \
      | sed -nE 's/.*"total_count":([0-9]+).*/\1/p' || true)"
    if [[ "${total:-0}" -gt 0 ]]; then
      info "127.0.0.1:$port — ${total}종목 보유"
      continue
    fi
    result="$(curl -s -X POST --max-time 180 "http://127.0.0.1:$port/api/symbols/collect" 2>/dev/null || true)"
    if grep -q '"success":true' <<<"$result"; then
      info "127.0.0.1:$port — 수집 완료 ($(sed -nE 's/.*"total_count":([0-9]+).*/\1/p' <<<"$result")종목)"
    else
      info "127.0.0.1:$port — 응답: ${result:-없음}"
      warn "종목 마스터 수집 실패 (127.0.0.1:$port). 화면 설정의 '종목 수집'으로 다시 시도하세요."
    fi
  done
}

check_url() {  # 이름 URL
  local name="$1" url="$2" code
  code="$(http_code "$url")"
  if [[ "$code" == "200" ]]; then
    info "OK   $name ($url)"
  else
    warn "$name 응답 이상: $url (HTTP ${code:-000})"
  fi
}

check_routes() {  # nginx 경유로 네 서비스와 정적 자원 라우팅을 확인한다
  local base="http://127.0.0.1:$WEB_PORT" asset
  check_url "전략 빌더 API" "$base/api/health"
  check_url "전략 빌더 전략 목록" "$base/api/strategies"
  check_url "백테스트 API" "$base/backtest/api/health"
  check_url "백테스트 전략 목록" "$base/backtest/api/strategies"
  check_url "전략 빌더 화면" "$base/builder"
  check_url "백테스트 화면" "$base/backtest"
  asset="$(curl -s --max-time 15 -K "$CURL_AUTH_CONFIG" "$base/backtest" 2>/dev/null \
    | grep -o '/backtest-static/_next/static/[^"]*\.js' | head -n 1 || true)"
  if [[ -n "$asset" ]]; then
    check_url "백테스트 정적 자원" "$base$asset"
  else
    warn "백테스트 화면에서 정적 자원 경로(/backtest-static)를 찾지 못했습니다."
  fi
}

health_check() {
  log "헬스체크 (nginx :$WEB_PORT 경유)"
  wait_upstreams
  CURL_AUTH_CONFIG="$(mktemp)"
  if [[ "$BASIC_AUTH" == "off" ]]; then
    check_routes
  else
    local anon credentials
    anon="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$WEB_PORT/builder" 2>/dev/null || true)"
    if [[ "$anon" == "401" ]]; then
      info "OK   인증 없는 접속 차단 (HTTP 401)"
    else
      warn "인증 없이 접속했는데 HTTP ${anon:-000} 응답 (401이어야 함)"
    fi
    if [[ -n "$BASIC_AUTH_PASSWORD" ]]; then
      credentials="$BASIC_AUTH_USER:$BASIC_AUTH_PASSWORD"
      credentials="${credentials//\\/\\\\}"
      credentials="${credentials//\"/\\\"}"
      printf 'user = "%s"\n' "$credentials" > "$CURL_AUTH_CONFIG"
      check_routes
    else
      info "Basic 인증 비밀번호를 알 수 없어 nginx 경유 라우팅 확인은 건너뜁니다."
    fi
  fi
  rm -f "$CURL_AUTH_CONFIG"

  local svc
  for svc in "${SERVICES[@]}" nginx; do
    as_root systemctl is-active --quiet "$svc" || warn "서비스 비활성: $svc (sudo journalctl -u $svc -n 100)"
  done
}

print_summary() {
  local host="${PUBLIC_HOST:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
  printf '\n==================================================\n'
  printf ' LIMSON 배포 결과\n'
  printf '  전략 빌더 : http://%s:%s/builder\n' "$host" "$WEB_PORT"
  printf '  백테스트  : http://%s:%s/backtest\n' "$host" "$WEB_PORT"
  printf '  로그인    : %s\n' "$AUTH_NOTE"
  printf '  PostgreSQL: %s\n' "$DB_STATUS"
  printf '  LEAN      : %s\n' "$LEAN_STATUS"
  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    printf '  경고 %d건:\n' "${#WARNINGS[@]}"
    printf '   - %s\n' "${WARNINGS[@]}"
  fi
  printf '  로그      : sudo journalctl -u open-trading-backtest-api -f  (서비스명: %s)\n' "${SERVICES[*]}"
  printf '==================================================\n'
}

main() {
  log "설치 위치: $APP_DIR (서비스 사용자: $SERVICE_USER)"
  [[ -f "$APP_DIR/strategy_builder/backend/main.py" && -f "$APP_DIR/backtester/backend/main.py" ]] \
    || die "저장소 구조가 예상과 다릅니다: $APP_DIR"
  # KIS 앱키와 DB 비밀번호가 들어 있는 파일은 서비스 사용자만 읽게 한다.
  chmod 600 "$APP_DIR/kis_devlp.yaml" "$APP_DIR/backtester/.env" 2>/dev/null || true
  install_system_packages
  ensure_docker
  ensure_swap
  ensure_node
  ensure_uv
  install_python_deps
  build_frontends
  configure_database
  setup_lean
  install_services
  wait_upstreams
  collect_symbol_masters
  configure_nginx
  health_check
  print_summary
}

main "$@"
