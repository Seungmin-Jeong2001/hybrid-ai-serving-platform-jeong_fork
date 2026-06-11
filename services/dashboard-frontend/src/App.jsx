import { useEffect, useState, useCallback } from "react";

const API_BASE = "/api";

function Clock() {
  const [time, setTime] = useState("");
  useEffect(() => {
    const tick = () =>
      setTime(new Date().toLocaleString("ko-KR", { timeZone: "Asia/Seoul" }) + " KST");
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, []);
  return <span className="clock">{time}</span>;
}

function Badge({ value }) {
  const isNormal = value === "정상" || value?.toLowerCase() === "normal";
  return (
    <span className={`badge ${isNormal ? "badge-normal" : "badge-abnormal"}`}>
      {value ?? "-"}
    </span>
  );
}

function formatTime(epochMs) {
  if (!epochMs) return "-";
  return new Date(epochMs).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" });
}

function formatLatency(requestedAt, completedAt) {
  if (!requestedAt || !completedAt) return "-";
  const diff = completedAt - requestedAt;
  return diff >= 1000 ? `${(diff / 1000).toFixed(1)}s` : `${diff}ms`;
}

function SummaryCards({ results }) {
  const total = results.length;
  const abnormal = results.filter(
    (r) => r.prediction !== "정상" && r.prediction?.toLowerCase() !== "normal"
  ).length;
  const normal = total - abnormal;
  const normalRate = total === 0 ? "-" : `${((normal / total) * 100).toFixed(1)}%`;

  return (
    <div className="summary-cards">
      <div className="summary-card">
        <div className="summary-label">총 추론 건수</div>
        <div className="summary-value" style={{ color: "var(--indigo)" }}>{total}</div>
        <div className="summary-sub">최근 50건 기준</div>
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
        <div className="summary-value" style={{ color: "var(--green)" }}>{normalRate}</div>
        <div className="summary-sub">정상 {normal}건 / 이상 {abnormal}건</div>
      </div>
    </div>
  );
}

export default function App() {
  const [results, setResults]       = useState([]);
  const [equipments, setEquipments] = useState([]);
  const [filter, setFilter]         = useState("");
  const [loading, setLoading]       = useState(false);
  const [error, setError]           = useState(null);

  const fetchEquipments = useCallback(async () => {
    try {
      const res = await fetch(`${API_BASE}/equipments`);
      const data = await res.json();
      setEquipments(data.equipments ?? []);
    } catch {
      // 장비 목록 실패는 무시
    }
  }, []);

  const fetchResults = useCallback(async (equipmentId = "") => {
    setLoading(true);
    setError(null);
    try {
      const url = equipmentId
        ? `${API_BASE}/results?equipment_id=${equipmentId}&limit=50`
        : `${API_BASE}/results?limit=50`;
      const res = await fetch(url);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      setResults(data.results ?? []);
    } catch (e) {
      setError("데이터를 불러오지 못했습니다.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchEquipments();
    fetchResults();
    const id = setInterval(() => fetchResults(filter), 10000);
    return () => clearInterval(id);
  }, []);

  const handleFilterChange = (e) => {
    const val = e.target.value;
    setFilter(val);
    fetchResults(val);
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
        html, body { font-family: 'Segoe UI', sans-serif; background: var(--bg); color: var(--text); min-height: 100vh; font-size: 14px; }
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
        .toolbar-left { display: flex; align-items: center; gap: 0.75rem; }
        .section-title { font-size: 0.75rem; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: 0.08em; }
        select { background: var(--surface); color: var(--text); border: 1px solid var(--border); border-radius: 0.4rem; padding: 0.35rem 0.75rem; font-size: 0.8rem; cursor: pointer; }
        select:focus { outline: none; border-color: var(--indigo); }
        .refresh-btn { background: var(--indigo); color: #fff; border: none; border-radius: 0.4rem; padding: 0.35rem 0.9rem; font-size: 0.8rem; cursor: pointer; }
        .refresh-btn:hover { opacity: 0.85; }
        .count-badge { font-size: 0.75rem; color: var(--sub); }
        .table-wrap { overflow-x: auto; border-radius: 0.75rem; border: 1px solid var(--border); }
        table { width: 100%; border-collapse: collapse; font-size: 0.8rem; }
        thead { background: var(--surface); }
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
        <Clock />
      </header>

      <main>
        <SummaryCards results={results} />

        <div className="toolbar">
          <div className="toolbar-left">
            <span className="section-title">추론 결과</span>
            <select value={filter} onChange={handleFilterChange}>
              <option value="">전체 장비</option>
              {equipments.map((eq) => (
                <option key={eq} value={eq}>{eq}</option>
              ))}
            </select>
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: "0.75rem" }}>
            <span className="count-badge">{results.length}건</span>
            <button className="refresh-btn" onClick={() => fetchResults(filter)}>새로고침</button>
          </div>
        </div>

        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>완료 시각</th>
                <th>장비 ID</th>
                <th>예측 결과</th>
                <th>소요 시간</th>
                <th>요청 ID</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={5} className="loading">불러오는 중...</td></tr>
              ) : error ? (
                <tr><td colSpan={5} className="error">{error}</td></tr>
              ) : results.length === 0 ? (
                <tr><td colSpan={5} className="empty">추론 결과가 없습니다.</td></tr>
              ) : (
                results.map((r) => (
                  <tr key={r.request_id}>
                    <td>{formatTime(r.completed_at)}</td>
                    <td>{r.equipment_id ?? "-"}</td>
                    <td><Badge value={r.prediction} /></td>
                    <td>{formatLatency(r.requested_at, r.completed_at)}</td>
                    <td style={{ color: "var(--muted)", fontSize: "0.7rem" }}>{r.request_id}</td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </main>
    </>
  );
}
