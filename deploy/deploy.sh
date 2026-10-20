#!/usr/bin/env bash
# 로컬 PC(WSL 등)에서 실행: 현재 소스를 EC2 VM으로 올리고 deploy/server_setup.sh로 설치·빌드·재시작한다.
#
#   ./deploy/deploy.sh
#
# 환경변수(모두 선택):
#   DEPLOY_HOST=13.209.87.155        서버 주소
#   WEB_PORT=8010                    웹 공개 포트
#   KEY_DIR=/home/l/stock-coin-trade SSH 키(*.pem, *.key)를 찾을 폴더
#   SSH_KEY=/path/to/key.pem         키 파일을 직접 지정
#   SSH_USER=ubuntu                  지정하지 않으면 ubuntu → ec2-user → root 순으로 시도
#   SSH_PORT=22                      지정하지 않으면 22 → 8010 순으로 시도
#   REMOTE_DIR=open-trading-api      서버 홈 디렉터리 기준 설치 위치
# 서버 스크립트로 전달되는 값: DATABASE_URL, BASIC_AUTH, BASIC_AUTH_USER, BASIC_AUTH_PASSWORD,
#   SKIP_LEAN_PULL, FORCE_LEAN_PULL, LEAN_MIN_FREE_GB, CREATE_SWAP (설명은 deploy/server_setup.sh)
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_HOST="${DEPLOY_HOST:-13.209.87.155}"
WEB_PORT="${WEB_PORT:-8010}"
KEY_DIR="${KEY_DIR:-/home/l/stock-coin-trade}"
REMOTE_DIR="${REMOTE_DIR:-open-trading-api}"
LOG_FILE="$ROOT_DIR/deploy/last-deploy.log"
PASS_THROUGH_VARS=(DATABASE_URL BASIC_AUTH BASIC_AUTH_USER BASIC_AUTH_PASSWORD SKIP_LEAN_PULL FORCE_LEAN_PULL LEAN_MIN_FREE_GB CREATE_SWAP)

log() { printf '\n\033[1;34m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[경고]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[실패]\033[0m %s\n' "$*" >&2; exit 1; }

for cmd in ssh tar curl git; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd 명령이 필요합니다 (sudo apt install -y openssh-client tar curl git)."
done

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
KNOWN_HOSTS="${HOME}/.ssh/known_hosts"
mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"

SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o IdentitiesOnly=yes
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=10
  -o LogLevel=ERROR
)

find_keys() {
  if [[ -n "${SSH_KEY:-}" ]]; then
    [[ -f "$SSH_KEY" ]] || die "SSH_KEY 파일이 없습니다: $SSH_KEY"
    printf '%s\n' "$SSH_KEY"
    return 0
  fi
  [[ -d "$KEY_DIR" ]] || die "키 폴더가 없습니다: $KEY_DIR (SSH_KEY=키파일경로 로 지정하세요)"
  local depth
  for depth in 1 3; do
    find "$KEY_DIR" -maxdepth "$depth" -type f \
      \( -name '*.pem' -o -name '*.key' -o -name 'id_rsa' -o -name 'id_ed25519' -o -name 'id_ecdsa' \) \
      2>/dev/null | sort | grep . && return 0
  done
  die "$KEY_DIR 에서 *.pem / *.key 파일을 찾지 못했습니다 (SSH_KEY=키파일경로 로 지정하세요)."
}

tcp_open() { timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

# 키 × 포트 × 사용자 조합으로 접속을 시도해 처음 성공한 조합을 쓴다.
connect_probe() {
  local -a keys ports users
  mapfile -t keys < <(find_keys)
  [[ ${#keys[@]} -gt 0 ]] || exit 1  # find_keys가 이유를 이미 출력했다
  read -r -a ports <<<"${SSH_PORT:-22 8010}"
  read -r -a users <<<"${SSH_USER:-ubuntu ec2-user root}"

  local key port user i=0 errors="$WORK_DIR/ssh-errors.txt"
  : > "$errors"
  for port in "${ports[@]}"; do
    if ! tcp_open "$DEPLOY_HOST" "$port"; then
      echo "$DEPLOY_HOST:$port TCP 연결 불가" >> "$errors"
      continue
    fi
    for key in "${keys[@]}"; do
      i=$((i + 1))
      # WSL의 /mnt/c 아래 키는 권한이 0777이라 ssh가 거부하므로 600으로 복사해서 쓴다.
      install -m 600 "$key" "$WORK_DIR/key$i"
      for user in "${users[@]}"; do
        if ssh "${SSH_OPTS[@]}" -i "$WORK_DIR/key$i" -p "$port" "$user@$DEPLOY_HOST" true 2>>"$errors"; then
          SSH_KEY_FILE="$WORK_DIR/key$i"
          SSH_PORT_FOUND="$port"
          SSH_USER_FOUND="$user"
          log "SSH 접속 성공: $user@$DEPLOY_HOST:$port (키: $key)"
          return 0
        fi
        echo "  ↑ $user@$DEPLOY_HOST:$port, key=$key" >> "$errors"
      done
    done
  done
  cat "$errors" >&2
  die "SSH 접속에 실패했습니다. SSH_USER / SSH_PORT / SSH_KEY 를 지정해 다시 실행하세요."
}

ssh_run() {
  ssh "${SSH_OPTS[@]}" -i "$SSH_KEY_FILE" -p "$SSH_PORT_FOUND" "$SSH_USER_FOUND@$DEPLOY_HOST" "$@"
}

list_files() {  # git이 추적하는 파일(커밋 안 된 수정 포함)만 보낸다. node_modules/.venv/.next 등은 서버에서 새로 만든다.
  git -C "$ROOT_DIR" ls-files -z | while IFS= read -r -d '' path; do
    [[ -e "$ROOT_DIR/$path" ]] && printf '%s\0' "$path"
  done
}

upload_source() {
  log "소스 전송 → ~/$REMOTE_DIR"
  git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git 저장소에서 실행하세요: $ROOT_DIR"
  local remote_dir_q
  remote_dir_q="$(printf '%q' "$REMOTE_DIR")"
  (cd "$ROOT_DIR" && list_files | tar --null -T - -czf -) \
    | ssh_run "mkdir -p $remote_dir_q && tar -xzf - -C $remote_dir_q"
}

run_server_setup() {
  log "서버 설치/빌드/재시작 (deploy/server_setup.sh) — 처음에는 수 분 이상 걸립니다"
  local env_file="$WORK_DIR/deploy.env" var remote_env=".open-trading-api-deploy.env"
  {
    printf 'WEB_PORT=%q\n' "$WEB_PORT"
    printf 'PUBLIC_HOST=%q\n' "$DEPLOY_HOST"
    for var in "${PASS_THROUGH_VARS[@]}"; do
      [[ -n "${!var:-}" ]] && printf '%s=%q\n' "$var" "${!var}"
    done
  } > "$env_file"
  # 비밀번호가 명령줄에 남지 않도록 설정은 파일로 넘기고 서버 스크립트가 읽은 뒤 지운다.
  ssh_run "umask 077 && cat > ~/$remote_env" < "$env_file"

  local tty=()
  [[ -t 0 && -t 1 ]] && tty=(-t)
  set +e
  ssh "${SSH_OPTS[@]}" "${tty[@]+"${tty[@]}"}" -i "$SSH_KEY_FILE" -p "$SSH_PORT_FOUND" "$SSH_USER_FOUND@$DEPLOY_HOST" \
    "cd $(printf '%q' "$REMOTE_DIR") && bash deploy/server_setup.sh --env-file ~/$remote_env" 2>&1 | tee "$LOG_FILE"
  local status=${PIPESTATUS[0]}
  set -e
  [[ $status -eq 0 ]] || die "서버 설정이 실패했습니다 (exit $status). 로그: $LOG_FILE"
}

check_public_access() {
  log "외부 접속 확인: http://$DEPLOY_HOST:$WEB_PORT"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://$DEPLOY_HOST:$WEB_PORT/builder" || true)"
  case "$code" in
    200|401)
      printf '  OK (HTTP %s) — 브라우저에서 http://%s:%s 접속\n' "$code" "$DEPLOY_HOST" "$WEB_PORT"
      ;;
    *)
      warn "외부에서 $WEB_PORT 포트에 접속하지 못했습니다 (HTTP ${code:-000})."
      warn "AWS 콘솔 → EC2 → 보안 그룹 → 인바운드 규칙에 'TCP $WEB_PORT, 소스: 내 IP(또는 0.0.0.0/0)'를 추가하세요."
      ;;
  esac
}

main() {
  log "대상: $DEPLOY_HOST (웹 포트 $WEB_PORT)"
  connect_probe
  if [[ "$SSH_PORT_FOUND" == "$WEB_PORT" ]]; then
    die "SSH가 $WEB_PORT 포트로 연결되었습니다. 웹 포트와 겹치므로 WEB_PORT=다른포트 로 지정해 다시 실행하세요."
  fi
  upload_source
  run_server_setup
  check_public_access
}

main "$@"
