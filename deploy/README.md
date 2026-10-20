# 서버 배포 (EC2 VM · 단일 포트 8010)

전략 빌더와 백테스터(백엔드 2개 + 프론트엔드 2개)를 EC2 VM 한 대에 올리고
`http://13.209.87.155:8010` 한 주소로 웹 서비스합니다. PostgreSQL은 VM에 이미 떠 있는 것을 찾아 연결합니다.

```
브라우저 ──► nginx :8010 (Basic 인증)
              ├─ /backtest/api/*  → 백테스트 API   FastAPI 127.0.0.1:8002 ──► PostgreSQL(VM) · Docker LEAN
              ├─ /backtest*       → 백테스트 화면  Next.js 127.0.0.1:3001 (자원: /backtest-static/_next)
              ├─ /api/*           → 전략 빌더 API  FastAPI 127.0.0.1:8000 (실시간 호가 WebSocket 포함)
              └─ /                → 전략 빌더 화면 Next.js 127.0.0.1:3000 (/builder, /execute)
```

네 서비스는 systemd에 등록되어 죽으면 자동 재시작되고, VM 재부팅 후에도 자동으로 올라옵니다.
백엔드/프론트엔드 포트는 127.0.0.1에만 열리고 외부에는 nginx(8010)만 노출됩니다.

## 사전 준비

| 항목 | 내용 |
|------|------|
| 보안 그룹 | EC2 인바운드 규칙에 **TCP 8010**(웹)과 **TCP 22**(SSH) 허용 |
| 디스크 | 백테스트 엔진 이미지 `quantconnect/lean:latest`가 압축 기준 약 14GB(amd64)라 **여유 50GB 이상** 권장. 부족하면 이미지 다운로드만 건너뛰고(백테스트 실행 불가) 나머지는 정상 동작 |
| 로컬 PC | `ssh`, `tar`, `curl`, `git` (WSL Ubuntu 기본 제공) |
| SSH 키 | `/home/l/stock-coin-trade/` 안의 `*.pem` / `*.key` 를 자동으로 찾음 |

## 배포

로컬 PC(WSL)의 저장소 루트에서 실행합니다. git이 추적하는 파일(커밋 안 된 수정 포함)이 그대로 서버로 올라갑니다.

```bash
./deploy/deploy.sh
```

하는 일:

1. 키 폴더의 키 × SSH 포트(22 → 8010) × 사용자(ubuntu → ec2-user → root) 조합으로 접속 시도
2. 소스를 서버 `~/open-trading-api` 로 전송
3. 서버에서 `deploy/server_setup.sh` 실행
   - nginx·Docker 설치 확인, Node.js 22 / uv 설치(없을 때만), 메모리 3GB 미만이면 2GB 스왑 생성
   - `uv sync`, `npm ci`, `next build`
   - PostgreSQL 자동 탐지 → `/etc/open-trading-api/app.env` 의 `DATABASE_URL` 로 저장
   - LEAN 이미지/데이터 준비, 종목 마스터(코스피·코스닥) 수집
   - systemd 서비스 4개 + nginx(:8010) 설정, 헬스체크 후 결과 요약 출력
4. 로컬에서 `http://13.209.87.155:8010` 외부 접속 확인 (안 되면 보안 그룹 안내)

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
| `WEB_PORT` | `8010` | 웹 공개 포트 |
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

- 전략 빌더: `http://13.209.87.155:8010/builder`
- 백테스트: `http://13.209.87.155:8010/backtest`
- 로그인: 첫 배포 결과에 출력된 ID/PW (서버의 `~/.open-trading-api-web-credentials` 에도 저장)

## PostgreSQL 연결

`DATABASE_URL` 을 지정하지 않으면 아래 순서로 후보를 만들어 실제로 접속해 보고,
`backtester/.env` 의 `PG_OHLCV_TABLE`(기본 `public.ohlcv`)이 있는 첫 번째 주소를 씁니다.

1. 이전 배포에서 저장한 값 (`/etc/open-trading-api/app.env`)
2. `backtester/.env` 의 `DATABASE_URL` (`127.0.0.1:55432`)
3. VM에서 실행 중인 PostgreSQL Docker 컨테이너 — 컨테이너 환경변수(`POSTGRES_USER/PASSWORD/DB`)와 포트 매핑·컨테이너 IP
4. `backtester/.env` 계정으로 `127.0.0.1:55432`, `127.0.0.1:5432`

선택된 값은 systemd 환경변수로 들어가 `backtester/.env` 보다 우선합니다. 로컬 개발용 `backtester/.env` 는 그대로 둡니다.

## 서버 운영 명령

```bash
# 상태 / 로그
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
| 외부에서 접속 안 됨 | EC2 보안 그룹에 TCP 8010 허용. 서버 안에서는 `curl -u admin:비번 http://127.0.0.1:8010/api/health` |
| 백테스트 시 "Lean 이미지가 없습니다" | 디스크 확보 후 `sudo docker pull quantconnect/lean:latest` (또는 `FORCE_LEAN_PULL=1 ./deploy/deploy.sh`) |
| "PostgreSQL 데이터 준비 실패" | 배포 요약의 PostgreSQL 줄 확인, 필요하면 `DATABASE_URL=... ./deploy/deploy.sh` |
| 종목명이 안 보임 | 화면 설정의 종목 수집 실행 (배포 시 자동 수집이 실패한 경우) |
| SSH 실패 | `SSH_KEY`, `SSH_USER`, `SSH_PORT` 를 직접 지정. 키 파일 권한 문제는 스크립트가 600 사본으로 처리 |

## 로컬 개발

`./start.sh` 등 기존 로컬 실행 방식은 바뀌지 않습니다. 단일 포트용 경로 설정(`/backtest` API·자원 prefix)은
서버에서만 `frontend/.env.production.local` 로 생성됩니다.
