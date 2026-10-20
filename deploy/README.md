# 서버 배포 (EC2 VM · 단일 포트 8011)

전략 빌더와 백테스터(백엔드 2개 + 프론트엔드 2개)를 EC2 VM 한 대에 올리고
`http://13.209.87.155:8011` 한 주소로 웹 서비스합니다. PostgreSQL은 VM에 이미 떠 있는 것을 찾아 연결합니다.
같은 VM의 8010 포트는 기존 `pg-stock-api` 컨테이너(OHLCV 수집·조회 API)가 쓰므로 건드리지 않습니다.

```
브라우저 ──► nginx :8011 (Basic 인증)
              ├─ /backtest/api/*  → 백테스트 API   127.0.0.1:8002 ──► PostgreSQL(VM) · Docker LEAN
              │                     (BACKTEST_MODE=local이면 로컬 PC 워커로 가는 SSH 역터널, 아래 참고)
              ├─ /backtest*       → 백테스트 화면  Next.js 127.0.0.1:3001 (자원: /backtest-static/_next)
              ├─ /api/*           → 전략 빌더 API  FastAPI 127.0.0.1:8000 (실시간 호가 WebSocket 포함)
              └─ /                → 전략 빌더 화면 Next.js 127.0.0.1:3000 (/builder, /execute)
```

서비스는 systemd에 등록되어 죽으면 자동 재시작되고, VM 재부팅 후에도 자동으로 올라옵니다.
백엔드/프론트엔드 포트는 127.0.0.1에만 열리고 외부에는 nginx(8011)만 노출됩니다.

## 사전 준비

| 항목 | 내용 |
|------|------|
| 보안 그룹 | EC2 인바운드 규칙에 **TCP 8011**(웹)과 **TCP 22**(SSH) 허용 |
| 디스크 | 백테스트 엔진 이미지 `quantconnect/lean:latest`가 압축 기준 약 14GB, 풀면 약 42GB(amd64)라 서버에서 돌리려면 **여유 50GB 이상** 필요. 작은 서버는 `BACKTEST_MODE=local`(로컬 PC에서 실행) 사용 |
| 로컬 PC | `ssh`, `tar`, `curl`, `git`, Node.js 20.9+ (프론트엔드를 로컬에서 빌드) |
| SSH 키 | `/home/l/stock-coin-trade/` 안의 `*.pem` / `*.key` 를 자동으로 찾음 |

## 배포

로컬 PC(WSL)의 저장소 루트에서 실행합니다. git이 추적하는 파일(커밋 안 된 수정 포함)이 그대로 서버로 올라갑니다.

```bash
# 13.209.87.155 (t3.micro, 디스크 30GB): 백테스트는 로컬 PC에서 실행
BACKTEST_MODE=local ./deploy/deploy.sh      # 처음 한 번. 이후에는 ./deploy/deploy.sh 만 해도 모드가 유지됨
./deploy/local_backtest_worker.sh install   # 로컬 PC에서 백테스트 워커 시작 (한 번)
```

하는 일 (`deploy.sh`):

1. 키 폴더의 키 × 사용자(ubuntu → ec2-user → root) 조합으로 접속 시도
2. 프론트엔드 2개를 **로컬 PC에서** `next build` (git 추적 파일만 임시 폴더에 복사해서 빌드 — 작업 폴더의 `.next` 는 건드리지 않음)
3. 소스와 빌드 결과(`.next`)를 서버 `~/open-trading-api` 로 전송
4. 서버에서 `deploy/server_setup.sh` 실행
   - nginx·Docker 설치 확인, Node.js 22 / uv 설치(없을 때만), 메모리 3GB 미만이면 2GB 스왑 생성
   - `uv sync`, `npm ci`, 로컬 빌드 결과 적용 (없으면 서버에서 `next build`)
   - PostgreSQL 자동 탐지 → `/etc/open-trading-api/app.env` 의 `DATABASE_URL` 로 저장
   - (`BACKTEST_MODE=server`일 때만) LEAN 이미지/데이터 준비, 백테스트 API 실행
   - 종목 마스터(코스피·코스닥) 수집, systemd 서비스 + nginx(:8011) 설정, 헬스체크 후 결과 요약 출력
5. 로컬에서 `http://13.209.87.155:8011` 외부 접속 확인 (안 되면 보안 그룹 안내)

처음 배포에는 수 분(LEAN 이미지 다운로드 포함 시 그 이상) 걸리고, 이후 재배포는 같은 명령으로 하면 됩니다.
실행 로그는 `deploy/last-deploy.log` 에 남습니다.

### 옵션 (환경변수)

```bash
SSH_KEY=/home/l/stock-coin-trade/my.pem SSH_USER=ubuntu ./deploy/deploy.sh
DATABASE_URL='postgresql://admin:비밀번호@127.0.0.1:55432/admin' ./deploy/deploy.sh
BASIC_AUTH_PASSWORD='새비밀번호' ./deploy/deploy.sh
```

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `DEPLOY_HOST` | `13.209.87.155` | 서버 주소 |
| `WEB_PORT` | `8011` | 웹 공개 포트 (8010은 서버의 pg-stock-api가 사용) |
| `BACKTEST_MODE` | 지난 배포 값, 처음이면 `server` | `local`: 백테스트 API+LEAN을 로컬 PC 워커에서 실행 / `server`: 서버에서 실행 |
| `FRONTEND_BUILD` | `local` | `local`: 로컬 PC에서 빌드해 결과만 업로드 / `server`: 서버에서 빌드 |
| `KEY_DIR` / `SSH_KEY` | `/home/l/stock-coin-trade` | 키 폴더 / 키 파일 직접 지정 |
| `SSH_USER` / `SSH_PORT` | 자동 탐색 | 접속 사용자 / 포트 |
| `REMOTE_DIR` | `open-trading-api` | 서버 홈 기준 설치 위치 |
| `DATABASE_URL` | 자동 탐지 | PostgreSQL 접속 주소 (지정하면 그대로 사용) |
| `BASIC_AUTH` | `on` | `off` 면 인증 없이 공개 (주문·계좌 API까지 공개되므로 권장하지 않음) |
| `BASIC_AUTH_USER` / `BASIC_AUTH_PASSWORD` | `admin` / 자동 생성 | 웹 로그인 계정. 비밀번호를 비우면 기존 값 유지 |
| `SKIP_LEAN_PULL` | `0` | `1` 이면 LEAN 이미지 다운로드 생략 |
| `FORCE_LEAN_PULL` / `LEAN_MIN_FREE_GB` | `0` / `50`(arm64 `20`) | 디스크 여유 검사 무시 / 기준 변경 |
| `CREATE_SWAP` | `1` | `0` 이면 스왑 파일 자동 생성 안 함 |

## 접속

- 전략 빌더: `http://13.209.87.155:8011/builder`
- 백테스트: `http://13.209.87.155:8011/backtest`
- 로그인: 첫 배포 결과에 출력된 ID/PW (서버의 `~/.open-trading-api-web-credentials` 에도 저장)

## PostgreSQL 연결

`DATABASE_URL` 을 지정하지 않으면 아래 순서로 후보를 만들어 실제로 접속해 보고,
`backtester/.env` 의 `PG_OHLCV_TABLE`(기본 `public.ohlcv`)이 있는 첫 번째 주소를 씁니다.

1. 이전 배포에서 저장한 값 (`/etc/open-trading-api/app.env`)
2. `backtester/.env` 의 `DATABASE_URL` (`127.0.0.1:55432`)
3. VM에서 실행 중인 PostgreSQL Docker 컨테이너 — 컨테이너 환경변수(`POSTGRES_USER/PASSWORD/DB`)와 포트 매핑·컨테이너 IP
4. `backtester/.env` 계정으로 `127.0.0.1:55432`, `127.0.0.1:5432`

선택된 값은 systemd 환경변수로 들어가 `backtester/.env` 보다 우선합니다. 로컬 개발용 `backtester/.env` 는 그대로 둡니다.

## 백테스트를 로컬 PC에서 실행 (BACKTEST_MODE=local)

LEAN 이미지는 풀면 약 42GB이고 백테스트 한 번에 메모리도 수 GB를 씁니다. t3.micro(메모리 1GB, 디스크 30GB)에는 둘 수 없으므로
웹 화면은 EC2에서, 백테스트 API와 LEAN은 로컬 PC(WSL)에서 돌리고 SSH 터널로 잇습니다.

```
브라우저 → EC2 nginx :8011 /backtest/api → EC2 127.0.0.1:8002 ═(SSH 역터널)═► 로컬 PC 127.0.0.1:18002 백테스트 API → 로컬 Docker LEAN
                                                   로컬 PC 백테스트 API → 로컬 127.0.0.1:15432 ═(SSH 터널)═► EC2 PostgreSQL
```

- 터널은 로컬 PC가 EC2로 SSH(22) 접속해서 만들므로 보안 그룹에 추가로 열 포트가 없습니다.
- 백테스트 데이터는 EC2의 PostgreSQL(최신 수집분)을 그대로 씁니다. 로컬의 `backtester/.env` 는 바뀌지 않습니다.
- 워커 포트 18002는 로컬 개발용 `./start.sh`(8002)와 겹치지 않으므로 둘을 함께 켜 둘 수 있습니다.
- **로컬 PC(WSL)가 꺼져 있으면** 백테스트 화면은 열리지만 실행·조회 API가 502 오류를 냅니다. 전략 빌더는 영향 없습니다.
- 연결이 끊기면 워커가 5초마다 다시 접속하고, 서버에 남은 이전 터널은 자동으로 정리합니다.
- 백테스트 결과·사용자 전략 파일은 로컬 PC의 `backtester/` 아래에 저장됩니다.

```bash
./deploy/local_backtest_worker.sh install    # systemd 사용자 서비스로 등록 (WSL이 켜지면 자동 시작)
./deploy/local_backtest_worker.sh status     # 로컬 API / 서버 쪽 터널 상태
./deploy/local_backtest_worker.sh logs       # 로그
./deploy/local_backtest_worker.sh uninstall  # 중지·삭제
```

서버가 커지면(디스크 50GB+, 메모리 4GB+) `BACKTEST_MODE=server ./deploy/deploy.sh` 로 되돌리고 로컬 워커는 `uninstall` 합니다.

## 서버 운영 명령

```bash
# 상태 / 로그 (BACKTEST_MODE=local이면 open-trading-backtest-api는 없음)
sudo systemctl status open-trading-strategy-api open-trading-backtest-api open-trading-strategy-web open-trading-backtest-web nginx
sudo journalctl -u open-trading-backtest-api -f

# 재시작
sudo systemctl restart open-trading-backtest-api

# 서버에서 직접 재설치/재빌드 (소스는 그대로)
bash ~/open-trading-api/deploy/server_setup.sh
```

## 문제 해결

| 증상 | 확인 |
|------|------|
| 외부에서 접속 안 됨 | EC2 보안 그룹에 TCP 8011 허용. 서버 안에서는 `curl -u admin:비번 http://127.0.0.1:8011/api/health` |
| 백테스트 화면에서 API 502 | `BACKTEST_MODE=local` 이면 로컬 PC에서 `./deploy/local_backtest_worker.sh status` (WSL이 켜져 있어야 함) |
| 백테스트 시 "Lean 이미지가 없습니다" | 디스크 확보 후 `sudo docker pull quantconnect/lean:latest` (또는 `FORCE_LEAN_PULL=1 ./deploy/deploy.sh`) |
| "PostgreSQL 데이터 준비 실패" | 배포 요약의 PostgreSQL 줄 확인, 필요하면 `DATABASE_URL=... ./deploy/deploy.sh` |
| 종목명이 안 보임 | 화면 설정의 종목 수집 실행 (배포 시 자동 수집이 실패한 경우) |
| SSH 실패 | `SSH_KEY`, `SSH_USER`, `SSH_PORT` 를 직접 지정. 키 파일 권한 문제는 스크립트가 600 사본으로 처리 |

## 로컬 개발

`./start.sh` 등 기존 로컬 실행 방식은 바뀌지 않습니다. 단일 포트용 경로 설정(`/backtest` API·자원 prefix)은
서버에서만 `frontend/.env.production.local` 로 생성됩니다.
