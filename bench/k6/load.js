// k6 load driver for OptRails.
//
// Run from a NEUTRAL location (not inside any provider's network), and run the
// SAME invocation against each platform URL. It finds sustained RPS under a
// p95 latency SLO by ramping arrival rate until the SLO breaks.
//
// Usage:
//   BASE_URL=https://your-app.fly.dev SCENARIO=cpu \
//   k6 run --out json=raw.json bench/k6/load.js
//
// Env:
//   BASE_URL   target app base url (required)
//   SCENARIO   one of: cpu | io | db_read | db_write | db_latency | mixed
//   START_RPS  starting arrival rate           (default 10)
//   MAX_RPS    max arrival rate to ramp to     (default 500)
//   STAGE_SEC  seconds per ramp stage          (default 30)
//   SLO_MS     p95 latency ceiling in ms       (default 200)
//   WORK       cpu work param                  (default 20)
//   IO_MS      io sleep param                  (default 50)

import http from 'k6/http';
import { check } from 'k6';
import { Trend, Rate } from 'k6/metrics';

const BASE = __ENV.BASE_URL;
const SCENARIO = __ENV.SCENARIO || 'mixed';
const START_RPS = parseInt(__ENV.START_RPS || '10');
const MAX_RPS = parseInt(__ENV.MAX_RPS || '500');
const STAGE_SEC = parseInt(__ENV.STAGE_SEC || '30');
const SLO_MS = parseInt(__ENV.SLO_MS || '200');
const WORK = __ENV.WORK || '20';
const IO_MS = __ENV.IO_MS || '50';

const serverMs = new Trend('server_ms', true);
const okRate = new Rate('endpoint_ok');

// Ramp arrival rate in 5 steps from START to MAX. Whichever stage still meets
// the SLO gives you sustained RPS; crunch.py extracts the knee.
function stages() {
  const s = [];
  const steps = 5;
  for (let i = 1; i <= steps; i++) {
    const target = Math.round(START_RPS + (MAX_RPS - START_RPS) * (i / steps));
    s.push({ target, duration: `${STAGE_SEC}s` });
  }
  return s;
}

export const options = {
  discardResponseBodies: false,
  scenarios: {
    ramp: {
      executor: 'ramping-arrival-rate',
      startRate: START_RPS,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 2000,
      stages: stages(),
    },
  },
  thresholds: {
    // Recorded, not aborted — we WANT to see where it breaks.
    http_req_duration: [{ threshold: `p(95)<${SLO_MS}`, abortOnFail: false }],
  },
};

function path() {
  switch (SCENARIO) {
    case 'cpu': return `/bench/cpu?work=${WORK}`;
    case 'io': return `/bench/io?ms=${IO_MS}`;
    case 'db_read': return '/bench/db_read';
    case 'db_write': return '/bench/db_write';
    case 'db_latency': return '/bench/db_latency';
    case 'mixed':
    default: {
      const r = Math.random();
      if (r < 0.5) return '/bench/db_read';
      if (r < 0.7) return `/bench/cpu?work=${WORK}`;
      if (r < 0.9) return '/bench/db_write';
      return `/bench/io?ms=${IO_MS}`;
    }
  }
}

export default function () {
  const res = http.get(`${BASE}${path()}`);
  okRate.add(res.status === 200);
  check(res, { 'status 200': (r) => r.status === 200 });
  try {
    const body = res.json();
    if (body && body.server_ms !== undefined) serverMs.add(body.server_ms);
  } catch (_e) { /* non-json / error page */ }
}

export function handleSummary(data) {
  return { 'summary.json': JSON.stringify(data, null, 2) };
}
