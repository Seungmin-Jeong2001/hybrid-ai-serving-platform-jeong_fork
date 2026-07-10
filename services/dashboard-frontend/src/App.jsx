import { useEffect, useState, useCallback, useRef } from "react";

const API_BASE = "/api";

function todayKST() {
  return new Date().toLocaleDateString("sv-SE", { timeZone: "Asia/Seoul" }); // YYYY-MM-DD
}

function LastUpdated({ time }) {
  if (!time) return <span className="clock">-</span>;
  return (
    <span className="clock">
      마지막 업데이트: {new Date(time).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" })}
    </span>
  );
}

const PREDICTION_LABEL = {
  normal: "정상상태",
  type1: "질량불균형 고장상태",
  type2: "지지불량 고장상태",
  type3: "질량불균형과 지지불량 고장상태",
};

function Badge({ value }) {
  const isNormal = value?.toLowerCase() === "normal";
  const label = PREDICTION_LABEL[value?.toLowerCase()] ?? value ?? "-";
  return (
    <span className={`badge ${isNormal ? "badge-normal" : "badge-abnormal"}`}>
      {label}
    </span>
  );
}

function formatTime(epochMs) {
  if (!epochMs) return "-";
  return new Date(epochMs).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" });
}

function SummaryCards({ summary }) {
  const { total = 0, normal = 0, abnormal = 0, normal_rate } = summary;
  const normalRateStr = normal_rate != null ? `${normal_rate}%` : "-";

  return (
    <div className="summary-cards">
      <div className="summary-card">
        <div className="summary-label">총 추론 건수</div>
        <div className="summary-value" style={{ color: "var(--indigo)" }}>{total}</div>
        <div className="summary-sub">금일 집계</div>
      </div>
      <div className="summary-card">
        <div className="summary-label">이상 감지</div>
        <div className="summary-value" style={{ color: abnormal > 0 ? "var(--red)" : "var(--green)" }}>
          {abnormal}
        </div>
        <div className="summary-sub">{abnormal > 0 ? "점검 필요" : "이상 없음"}</div>
      </div>
      <div className="summary-card">
        <div className="summary-label">정상 비율</div>
        <div className="summary-value" style={{ color: "var(--green)" }}>{normalRateStr}</div>
        <div className="summary-sub">정상 {normal}건 / 이상 {abnormal}건</div>
      </div>
    </div>
  );
}

export default function App() {
  const [summary, setSummary]         = useState({ total: 0, normal: 0, abnormal: 0, normal_rate: null });
  const [results, setResults]         = useState([]);
  const [equipments, setEquipments]   = useState([]);
  const [filter, setFilter]           = useState("");
  const [predFilter, setPredFilter]   = useState("");
  const [dateFilter, setDateFilter]   = useState(todayKST());
  const [loading, setLoading]         = useState(false);
  const [error, setError]             = useState(null);
  const [lastUpdated, setLastUpdated] = useState(null);
  const filterRef     = useRef("");
  const dateFilterRef = useRef(todayKST());
  const scrollRef     = useRef(null);

  const fetchSummary = useCallback(async () => {
    try {
      const res = await fetch(`${API_BASE}/summary`);
      const data = await res.json();
      setSummary(data);
    } catch {
      // 요약 실패는 무시
    }
  }, []);

  const fetchEquipments = useCallback(async () => {
    try {
      const res = await fetch(`${API_BASE}/equipments`);
      const data = await res.json();
      setEquipments(data.equipments ?? []);
    } catch {
      // 장비 목록 실패는 무시
    }
  }, []);

  const fetchResults = useCallback(async (equipmentId = "", date = "") => {
    setLoading(true);
    setError(null);
    try {
      const params = new URLSearchParams();
      if (equipmentId) params.set("equipment_id", equipmentId);
      if (date) params.set("date", date);
      const url = `${API_BASE}/results${params.toString() ? "?" + params.toString() : ""}`;
      const res = await fetch(url);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const scrollTop = scrollRef.current?.scrollTop ?? 0;
      setResults(data.results ?? []);
      setLastUpdated(Date.now());
      requestAnimationFrame(() => {
        if (scrollRef.current) scrollRef.current.scrollTop = scrollTop;
      });
    } catch (e) {
      setError("데이터를 불러오지 못했습니다.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchSummary();
    fetchEquipments();
    fetchResults(filterRef.current, dateFilterRef.current);
    const id = setInterval(() => {
      fetchSummary();
      fetchResults(filterRef.current, dateFilterRef.current);
    }, 10000);
    return () => clearInterval(id);
  }, []);

  const handleFilterChange = (e) => {
    const val = e.target.value;
    setFilter(val);
    filterRef.current = val;
    fetchResults(val, dateFilterRef.current);
  };

  const handleDateChange = (e) => {
    const val = e.target.value;
    setDateFilter(val);
    dateFilterRef.current = val;
    fetchResults(filterRef.current, val);
  };

  return (
    <>
      <style>{`
        * { margin: 0; padding: 0; box-sizing: border-box; }
        :root {
          --bg: #0f1117; --surface: #1a1d27; --border: #2d3148;
          --text: #e2e8f0; --muted: #64748b; --sub: #94a3b8;
          --green: #22c55e; --red: #ef4444; --indigo: #6366f1;
          --yellow: #eab308;
        }
        html, body { font-family: 'Segoe UI', sans-serif; background: var(--bg); color: var(--text); min-height: 100vh; font-size: 17px; }
        header { display: flex; align-items: center; justify-content: space-between; padding: 0.75rem 2rem; background: var(--surface); border-bottom: 1px solid var(--border); position: sticky; top: 0; z-index: 10; }
        header h1 { font-size: 1.1rem; font-weight: 700; color: #fff; }
        header h1 span { color: var(--indigo); }
        .clock { font-size: 0.8rem; color: var(--sub); }
        main { padding: 1.5rem 2rem; display: flex; flex-direction: column; gap: 1.2rem; }

        /* 요약 카드 */
        .summary-cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 0.75rem; }
        .summary-card { background: var(--surface); border: 1px solid var(--border); border-radius: 0.75rem; padding: 0.9rem 1.2rem; }
        .summary-label { font-size: 0.7rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 0.25rem; }
        .summary-value { font-size: 1.7rem; font-weight: 700; line-height: 1.2; }
        .summary-sub { font-size: 0.7rem; color: var(--muted); margin-top: 0.25rem; }

        .toolbar { display: flex; align-items: center; justify-content: space-between; gap: 1rem; flex-wrap: wrap; }
        .toolbar-left { display: flex; align-items: center; gap: 0.75rem; flex-wrap: wrap; }
        .section-title { font-size: 0.75rem; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: 0.08em; }
        select, input[type="date"] { background: var(--surface); color: var(--text); border: 1px solid var(--border); border-radius: 0.4rem; padding: 0.35rem 0.75rem; font-size: 0.8rem; cursor: pointer; }
        select:focus, input[type="date"]:focus { outline: none; border-color: var(--indigo); }
        input[type="date"]::-webkit-calendar-picker-indicator { filter: invert(0.6); cursor: pointer; }
        .refresh-btn { background: var(--indigo); color: #fff; border: none; border-radius: 0.4rem; padding: 0.35rem 0.9rem; font-size: 0.8rem; cursor: pointer; }
        .refresh-btn:hover { opacity: 0.85; }
        .count-badge { font-size: 0.75rem; color: var(--sub); }
        .table-wrap { overflow-x: auto; border-radius: 0.75rem; border: 1px solid var(--border); }
        .table-scroll { max-height: 60vh; overflow-y: auto; }
        table { width: 100%; border-collapse: collapse; font-size: 0.8rem; table-layout: fixed; }
        thead th, tbody td { width: 25%; }
        thead { background: var(--surface); position: sticky; top: 0; z-index: 1; }
        thead th { padding: 0.65rem 1rem; text-align: left; color: var(--muted); font-weight: 600; font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.05em; border-bottom: 1px solid var(--border); white-space: nowrap; }
        tbody tr { border-bottom: 1px solid var(--border); transition: background 0.15s; }
        tbody tr:last-child { border-bottom: none; }
        tbody tr:hover { background: #1e2130; }
        tbody td { padding: 0.6rem 1rem; color: var(--text); white-space: nowrap; }
        .badge { font-size: 0.7rem; font-weight: 700; padding: 2px 10px; border-radius: 1rem; }
        .badge-normal   { background: #22c55e22; color: var(--green); border: 1px solid #22c55e44; }
        .badge-abnormal { background: #ef444422; color: var(--red);   border: 1px solid #ef444444; }
        .empty { text-align: center; padding: 3rem; color: var(--muted); font-size: 0.85rem; }
        .error { text-align: center; padding: 3rem; color: var(--red); font-size: 0.85rem; }
        .loading { text-align: center; padding: 3rem; color: var(--sub); font-size: 0.85rem; }
        @media (max-width: 600px) { main { padding: 1rem; } header { padding: 0.6rem 1rem; } }
      `}</style>

      <header>
        <h1><span>HASP</span> 예지보전 모니터링 대시보드</h1>
        <LastUpdated time={lastUpdated} />
      </header>

      <main>
        <SummaryCards summary={summary} />

        <div className="toolbar">
          <div className="toolbar-left">
            <span className="section-title">추론 결과</span>
            <input
              type="date"
              value={dateFilter}
              max={todayKST()}
              onChange={handleDateChange}
            />
            <select value={filter} onChange={handleFilterChange}>
              <option value="">전체 장비</option>
              {equipments.map((eq) => (
                <option key={eq} value={eq}>{eq}</option>
              ))}
            </select>
            <select value={predFilter} onChange={(e) => setPredFilter(e.target.value)}>
              <option value="">전체 결과</option>
              <option value="normal">정상상태</option>
              <option value="type1">질량불균형 고장상태</option>
              <option value="type2">지지불량 고장상태</option>
              <option value="type3">질량불균형과 지지불량 고장상태</option>
            </select>
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: "0.75rem" }}>
            <span className="count-badge">{results.filter((r) => !predFilter || r.prediction?.toLowerCase() === predFilter).length}건</span>
            <button className="refresh-btn" onClick={() => { fetchSummary(); fetchResults(filter, dateFilter); }}>새로고침</button>
          </div>
        </div>

        <div className="table-wrap">
          <div className="table-scroll" ref={scrollRef}>
          <table>
            <thead>
              <tr>
                <th>감지 시각</th>
                <th>공장 ID</th>
                <th>장비 ID</th>
                <th>예측 결과</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={4} className="loading">불러오는 중...</td></tr>
              ) : error ? (
                <tr><td colSpan={4} className="error">{error}</td></tr>
              ) : results.length === 0 ? (
                <tr><td colSpan={4} className="empty">추론 결과가 없습니다.</td></tr>
              ) : (
                results
                  .filter((r) => !predFilter || r.prediction?.toLowerCase() === predFilter)
                  .map((r) => (
                    <tr key={r.request_id}>
                      <td>{formatTime(r.completed_at)}</td>
                      <td>{r.factory_id ?? "-"}</td>
                      <td>{r.equipment_id ?? "-"}</td>
                      <td><Badge value={r.prediction} /></td>
                    </tr>
                  ))
              )}
            </tbody>
          </table>
          </div>
        </div>
      </main>
    </>
  );
}
