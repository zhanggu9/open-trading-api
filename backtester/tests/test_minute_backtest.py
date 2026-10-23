"""분봉(1분봉) 백테스트 경로 테스트.

실제 KIS API·LEAN Docker 없이 검증한다.
- KIS 주식일별분봉조회 페이지네이션/휴장일 필터
- 날짜별 분봉 CSV 준비와 캐시
- 분봉용 LEAN 코드 생성과 생성된 데이터 리더 동작
- /api/backtest/run 의 resolution 처리
"""

import asyncio
import sys
import types
from datetime import date, datetime, timedelta
from pathlib import Path

import pytest
from fastapi import HTTPException

BACKTESTER_DIR = Path(__file__).resolve().parents[1]
if str(BACKTESTER_DIR) not in sys.path:
    sys.path.insert(0, str(BACKTESTER_DIR))

from kis_backtest.codegen.generator import CodeGenConfig, LeanCodeGenerator  # noqa: E402
from kis_backtest.exceptions import KISError  # noqa: E402
from kis_backtest.models import Bar  # noqa: E402
from kis_backtest.providers.kis.data import KISDataProvider  # noqa: E402
from kis_backtest.strategies.registry import StrategyRegistry  # noqa: E402
import kis_backtest.strategies.preset  # noqa: E402,F401  (전략 등록)


# ---------------------------------------------------------------------------
# KIS 분봉 조회
# ---------------------------------------------------------------------------

def _session_minutes(day: str) -> list[dict]:
    """09:00~15:19 + 15:30 체결 분봉 (KIS 응답 형식, 최신 시각이 먼저)."""
    rows = []
    t = datetime.strptime(f"{day}0900", "%Y%m%d%H%M")
    while t <= datetime.strptime(f"{day}1519", "%Y%m%d%H%M"):
        rows.append(t)
        t += timedelta(minutes=1)
    rows.append(datetime.strptime(f"{day}1530", "%Y%m%d%H%M"))
    return [
        {
            "stck_bsop_date": day,
            "stck_cntg_hour": r.strftime("%H%M%S"),
            "stck_oprc": "70000", "stck_hgpr": "70100", "stck_lwpr": "69900",
            "stck_prpr": "70050", "cntg_vol": "10",
        }
        for r in sorted(rows, reverse=True)
    ]


class _FakeResp:
    def __init__(self, rows=None, ok=True, code="", message=""):
        self._rows = rows or []
        self._ok = ok
        self.error_code = code
        self.error_message = message

    def is_ok(self):
        return self._ok

    def get_output2(self):
        return self._rows


class _FakeAuth:
    """FID_INPUT_HOUR_1 이하 시각을 최신순으로 최대 120건 돌려주는 가짜 KIS."""

    is_paper = False

    def __init__(self, days: dict[str, list[dict]], fail: bool = False):
        self.days = days
        self.fail = fail
        self.calls = []

    def get(self, endpoint, params, tr_id):
        self.calls.append((params["FID_INPUT_DATE_1"], params["FID_INPUT_HOUR_1"], tr_id))
        if self.fail:
            return _FakeResp(ok=False, code="EGW02004", message="모의투자에서는 해당업무가 제공되지 않습니다.")
        day = params["FID_INPUT_DATE_1"]
        hour = params["FID_INPUT_HOUR_1"]
        rows = [r for r in self.days.get(day, []) if r["stck_cntg_hour"] <= hour]
        return _FakeResp(rows[:120])

    def smart_sleep(self):
        pass


def test_minute_bars_paginate_full_session():
    day = "20261001"
    auth = _FakeAuth({day: _session_minutes(day)})
    bars = KISDataProvider(auth).get_minute_bars_for_date("005930", date(2026, 10, 1))

    assert len(bars) == 381  # 09:00~15:19 380개 + 15:30 종가 1개
    assert bars[0].time == datetime(2026, 10, 1, 9, 0)
    assert bars[-1].time == datetime(2026, 10, 1, 15, 30)
    assert all(a.time < b.time for a, b in zip(bars, bars[1:]))
    assert {c[2] for c in auth.calls} == {"FHKST03010230"}
    assert len(auth.calls) <= 5


def test_minute_bars_drop_other_business_dates():
    """휴장일 요청에 직전 거래일 데이터가 와도 그날 봉으로 쓰지 않는다."""
    holiday = "20261003"
    previous = _session_minutes("20261002")
    auth = _FakeAuth({holiday: previous})
    assert KISDataProvider(auth).get_minute_bars_for_date("005930", date(2026, 10, 3)) == []


def test_minute_bars_raise_on_api_error():
    auth = _FakeAuth({}, fail=True)
    with pytest.raises(KISError, match="분봉 조회 실패"):
        KISDataProvider(auth).get_minute_bars_for_date("005930", date(2026, 10, 1))


# ---------------------------------------------------------------------------
# LEAN 코드 생성
# ---------------------------------------------------------------------------

def _generate(resolution: str) -> str:
    definition = StrategyRegistry.build("sma_crossover")
    generator = LeanCodeGenerator(definition, config=CodeGenConfig(resolution=resolution))
    return generator.generate(["005930"], "2026-09-01", "2026-09-30", 100_000_000)


def test_codegen_minute_uses_minute_data_and_resolution():
    code = _generate("minute")
    assert 'f"/Data/equity/krx/minute/{symbol}/{date.strftime(\'%Y%m%d\')}.csv"' in code
    assert "self.AddData(KRXEquity, symbol_str, Resolution.Minute)" in code
    assert ", Resolution.Minute)" in code.split("self.SetWarmUp(")[1].splitlines()[0]
    # 벤치마크 지수는 일봉 그대로
    assert 'self.AddData(KRXIndex, "kospi", Resolution.Daily)' in code


def test_codegen_daily_is_unchanged():
    code = _generate("daily")
    assert 'source = f"/Data/equity/krx/daily/{symbol}.csv"' in code
    assert "self.AddData(KRXEquity, symbol_str, Resolution.Daily)" in code
    assert "Resolution.Minute" not in code


def test_codegen_rejects_unsupported_resolution():
    with pytest.raises(ValueError):
        CodeGenConfig(resolution="hour")
    with pytest.raises(ValueError):
        CodeGenConfig(market="us", resolution="minute")


def _load_generated_module(code: str) -> dict:
    """LEAN 없이 생성 코드의 데이터 클래스를 실행해 보기 위한 최소 스텁."""

    class PythonData(dict):
        def __setitem__(self, key, value):
            dict.__setitem__(self, key, value)

    class SubscriptionDataSource:
        def __init__(self, source, medium, fmt):
            self.Source = source

    class _Anything:
        def __getattr__(self, name):
            return name

    stub = types.ModuleType("AlgorithmImports")
    for name in ("SubscriptionTransportMedium", "FileFormat", "Resolution", "OrderDirection"):
        setattr(stub, name, _Anything())
    stub.PythonData = PythonData
    stub.SubscriptionDataSource = SubscriptionDataSource
    stub.FeeModel = object
    stub.QCAlgorithm = object
    stub.TradeBar = object
    stub.OrderFee = stub.CashAmount = lambda *a, **k: None
    sys.modules["AlgorithmImports"] = stub
    try:
        namespace: dict = {}
        exec(compile(code, "<lean_generated>", "exec"), namespace)
        return namespace
    finally:
        del sys.modules["AlgorithmImports"]


def test_generated_minute_reader_parses_kis_rows():
    ns = _load_generated_module(_generate("minute"))
    equity = ns["KRXEquity"]()
    config = types.SimpleNamespace(Symbol=types.SimpleNamespace(Value="005930"))

    source = equity.GetSource(config, datetime(2026, 9, 1), False)
    assert source.Source == "/Data/equity/krx/minute/005930/20260901.csv"

    bar = equity.Reader(config, "202609010901,70000,70100,69900,70050,1234", datetime(2026, 9, 1), False)
    assert bar.Time == datetime(2026, 9, 1, 9, 1)
    assert bar.EndTime == datetime(2026, 9, 1, 9, 2)
    assert bar["Close"] == 70050.0 and bar["Volume"] == 1234
    assert equity.Reader(config, "", datetime(2026, 9, 1), False) is None
    assert equity.Reader(config, "broken", datetime(2026, 9, 1), False) is None


# ---------------------------------------------------------------------------
# 분봉 데이터 준비 (/api/backtest)
# ---------------------------------------------------------------------------

@pytest.fixture
def backtest_routes():
    from backend.routes import backtest as routes
    return routes


def _recent_week() -> tuple[date, date]:
    """오늘 이전의 완전한 월~일 한 주."""
    today = date.today()
    last_sunday = today - timedelta(days=today.weekday() + 1)
    return last_sunday - timedelta(days=6), last_sunday


def test_prepare_minute_data_writes_daily_files_and_caches(tmp_path, monkeypatch, backtest_routes):
    monday, sunday = _recent_week()
    fetched = []

    class FakeProvider:
        def __init__(self, auth):
            pass

        def get_minute_bars_for_date(self, symbol, day):
            fetched.append((symbol, day))
            return [
                Bar(time=datetime.combine(day, datetime.min.time()).replace(hour=9, minute=m),
                    open=100, high=101, low=99, close=100.4, volume=5)
                for m in range(3)
            ]

    monkeypatch.setattr("kis_backtest.providers.kis.auth.KISAuth.from_env",
                        classmethod(lambda cls, mode=None: types.SimpleNamespace(is_paper=False)))
    monkeypatch.setattr("kis_backtest.providers.kis.data.KISDataProvider", FakeProvider)

    run = lambda: asyncio.run(backtest_routes.prepare_minute_market_data(  # noqa: E731
        ["005930"], monday.isoformat(), sunday.isoformat(), tmp_path))

    result = run()
    assert result["errors"] == [] and result["downloaded"] == ["005930"]
    assert [d for _, d in fetched] == [monday + timedelta(days=i) for i in range(5)]

    symbol_dir = tmp_path / "data" / "equity" / "krx" / "minute" / "005930"
    assert (symbol_dir / f"{monday:%Y%m%d}.csv").read_text().splitlines()[0] == \
        f"{monday:%Y%m%d}0900,100,101,99,100,5"
    assert (symbol_dir / f"{sunday:%Y%m%d}.csv").read_text() == ""  # 주말: 빈 파일
    assert (symbol_dir / f"{monday - timedelta(days=1):%Y%m%d}.csv").exists()  # 워밍업용 빈 파일

    fetched.clear()
    again = run()
    assert fetched == [] and again["skipped"] == ["005930"]


def test_prepare_minute_data_reports_paper_mode(tmp_path, monkeypatch, backtest_routes):
    monday, sunday = _recent_week()

    class FailingProvider:
        def __init__(self, auth):
            pass

        def get_minute_bars_for_date(self, symbol, day):
            raise KISError("분봉 조회 실패: 005930 - 모의투자에서는 해당업무가 제공되지 않습니다.")

    monkeypatch.setattr("kis_backtest.providers.kis.auth.KISAuth.from_env",
                        classmethod(lambda cls, mode=None: types.SimpleNamespace(is_paper=True)))
    monkeypatch.setattr("kis_backtest.providers.kis.data.KISDataProvider", FailingProvider)

    result = asyncio.run(backtest_routes.prepare_minute_market_data(
        ["005930", "000660"], monday.isoformat(), sunday.isoformat(), tmp_path))
    assert [e["symbol"] for e in result["errors"]] == ["005930", "000660"]
    assert "실전 인증" in result["errors"][0]["error"]


@pytest.mark.parametrize("start_offset,end_offset,message", [
    (400, 1, "최근 1년치"),
    (200, 1, "최대"),
    (3, -2, "오늘 이후"),
])
def test_validate_minute_range(backtest_routes, start_offset, end_offset, message):
    today = date.today()
    with pytest.raises(HTTPException) as exc:
        backtest_routes.validate_minute_range(
            (today - timedelta(days=start_offset)).isoformat(),
            (today - timedelta(days=end_offset)).isoformat(),
        )
    assert exc.value.status_code == 400 and message in exc.value.detail


def test_run_endpoint_minute_end_to_end(tmp_path, monkeypatch):
    """요청 → 분봉 준비 → 분봉 LEAN 코드 → 응답의 resolution 까지 (LEAN 실행만 가짜)."""
    from fastapi.testclient import TestClient

    from backend.main import app
    from backend.routes import backtest as routes
    from kis_backtest.lean.executor import LeanExecutor, LeanRun
    from kis_backtest.lean.project_manager import LeanProjectManager

    monkeypatch.setattr(LeanProjectManager, "workspace", tmp_path)
    calls = {}

    async def fake_minute(symbols, start_date, end_date, workspace):
        calls["minute"] = (symbols, start_date, end_date)
        return {"downloaded": symbols, "skipped": [], "errors": [], "source": "KIS 분봉"}

    async def fake_benchmark(**kwargs):
        return False

    def fake_run(project, **kwargs):
        calls["code"] = project.main_py.read_text()
        run = LeanRun(project=project, success=True, output_dir=project.output_dir)
        run.raw_result = {"statistics": {"Net Profit": "1.5%", "Start Equity": "100000000",
                                         "End Equity": "101500000"}, "charts": {}, "orders": {}}
        return run

    monkeypatch.setattr(routes, "prepare_minute_market_data", fake_minute)
    monkeypatch.setattr(routes, "prepare_benchmark_data", fake_benchmark)
    monkeypatch.setattr(LeanExecutor, "check_docker", classmethod(lambda cls: True))
    monkeypatch.setattr(LeanExecutor, "check_image", classmethod(lambda cls: True))
    monkeypatch.setattr(LeanExecutor, "run", classmethod(lambda cls, project, **kw: fake_run(project)))

    start = (date.today() - timedelta(days=10)).isoformat()
    end = (date.today() - timedelta(days=1)).isoformat()
    client = TestClient(app)
    response = client.post("/api/backtest/run", json={
        "strategy_id": "sma_crossover", "symbols": ["005930"],
        "start_date": start, "end_date": end, "resolution": "minute",
    })
    assert response.status_code == 200, response.text
    assert response.json()["data"]["resolution"] == "minute"
    assert calls["minute"] == (["005930"], start, end)
    assert "Resolution.Minute" in calls["code"]

    bad = client.post("/api/backtest/run", json={
        "strategy_id": "sma_crossover", "symbols": ["005930"],
        "start_date": start, "end_date": end, "resolution": "hour",
    })
    assert bad.status_code == 422


def test_prepare_minute_data_reports_network_error(tmp_path, monkeypatch, backtest_routes):
    import requests

    monday, sunday = _recent_week()

    def unreachable(cls, mode=None):
        raise requests.ConnectionError("Connection reset by peer")

    monkeypatch.setattr("kis_backtest.providers.kis.auth.KISAuth.from_env", classmethod(unreachable))
    result = asyncio.run(backtest_routes.prepare_minute_market_data(
        ["005930"], monday.isoformat(), sunday.isoformat(), tmp_path))
    error = result["errors"][0]["error"]
    assert "연결하지 못했습니다" in error and "실전 인증" not in error
