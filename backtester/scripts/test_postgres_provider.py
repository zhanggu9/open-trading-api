"""원격 PostgreSQL의 OHLCV를 PostgresDataProvider로 읽어 보는 테스트."""

from __future__ import annotations

import argparse
import os
import sys
from datetime import date
from pathlib import Path

import psycopg
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
load_dotenv(ROOT / ".env")

from kis_backtest.providers.postgres import PostgresDataProvider  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(
        description="PostgreSQL에서 국내 주식 일봉 OHLCV 조회를 테스트합니다."
    )
    parser.add_argument(
        "--symbol",
        help="종목코드 (예: 005930). 생략하면 public.ohlcv에서 하나를 자동 선택합니다.",
    )
    parser.add_argument("--start", default="2024-01-01", help="시작일 YYYY-MM-DD")
    parser.add_argument(
        "--end",
        default=date.today().isoformat(),
        help="종료일 YYYY-MM-DD",
    )
    args = parser.parse_args()

    dsn = os.getenv("DATABASE_URL")
    if not dsn:
        print("오류: backtester/.env에 DATABASE_URL을 설정하세요.")
        return 1

    try:
        symbol = args.symbol
        if not symbol:
            with psycopg.connect(dsn, connect_timeout=10) as conn:
                with conn.cursor() as cursor:
                    cursor.execute("""
                        SELECT ticker_code
                        FROM public.ohlcv
                        WHERE ticker_code IS NOT NULL
                        GROUP BY ticker_code
                        ORDER BY ticker_code
                        LIMIT 1
                    """)
                    row = cursor.fetchone()

            if not row:
                print("public.ohlcv 테이블에 종목 데이터가 없습니다.")
                return 2
            symbol = row[0]

        start = date.fromisoformat(args.start)
        end = date.fromisoformat(args.end)
        provider = PostgresDataProvider()
        bars = provider.get_history(symbol, start, end)

    except (psycopg.Error, ValueError, TypeError, NotImplementedError) as exc:
        print(f"조회 테스트 실패: {type(exc).__name__}: {exc}")
        return 1

    print("=== PostgreSQL OHLCV 조회 결과 ===")
    print(f"종목코드: {symbol}")
    print(f"요청 기간: {start} ~ {end}")
    print(f"조회 건수: {len(bars)}")

    if not bars:
        print("해당 종목과 기간에 데이터가 없습니다.")
        print("다른 종목코드 또는 날짜 범위로 다시 실행해 보세요.")
        return 2

    print("\n처음 데이터:")
    for bar in bars[:3]:
        print(
            f"{bar.time.date()} O={bar.open:g} H={bar.high:g} "
            f"L={bar.low:g} C={bar.close:g} V={bar.volume}"
        )

    print("\n마지막 데이터:")
    for bar in bars[-3:]:
        print(
            f"{bar.time.date()} O={bar.open:g} H={bar.high:g} "
            f"L={bar.low:g} C={bar.close:g} V={bar.volume}"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
