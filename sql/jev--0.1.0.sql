-- jev 0.1.0 — natural-language predicates for PostgreSQL, powered by TypeSafe's Jev.
--
--   SELECT * FROM people WHERE jev(people, 'name is european');
--   SELECT name, jev_prob(people, 'works in healthcare') AS p FROM people ORDER BY p DESC;
--   SELECT name, jev_score(products, 'how luxurious is this product', ARRAY['budget','mid-range','luxury']) FROM products;
--   SELECT subject, jev_choice(support_tickets, 'which team should handle this', ARRAY['billing','technical','sales']) FROM support_tickets;
--
-- No index is needed. Rows are judged by the model, not matched by pattern.
-- The extension batches all rows of the scanned table into a handful of
-- parallel API requests (many questions over one shared state) and caches the
-- answers per row content for the rest of the session, so re-running a query,
-- changing the threshold, or sorting by probability costs nothing extra.
--
-- Settings (SET jev.<name> = ...):
--   jev.api_key            TypeSafe API key (falls back to the TYPESAFE_API_KEY env var of the server)
--   jev.model              default 'jev-latest'
--   jev.threshold          default 0.5   probability at which jev() returns true
--   jev.batch_size         default 40    rows per API request
--   jev.concurrency        default 6     parallel API requests
--   jev.max_prefetch_rows  default 5000  rows read ahead from the scanned table
--   jev.notices            default 'on'  emit a NOTICE per batch run
--   jev.api_url            default 'https://api.typesafe.ai/v1/systemone' (proxies, mocks, tests)
--   jev.timeout            default 90    seconds per API request

\echo Use "CREATE EXTENSION jev" to load this file. \quit

CREATE FUNCTION _jev_eval(rel_type text, row_json text, query text, kind text, options text)
RETURNS jsonb
LANGUAGE plpython3u
STABLE
AS $py$
import json, os, time, hashlib, threading
import urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

USD_PER_INPUT_TOKEN = 0.042 / 1_000_000  # jev-1.13 list price; output tokens are free

# ---------------------------------------------------------------- session state
if "jev" not in GD:
    GD["jev"] = {
        "cache": {},          # key -> {row_hash: answer}
        "prefetched": {},     # key -> statement_timestamp of last table read-ahead
        "stats": {"requests": 0, "input_tokens": 0, "output_tokens": 0,
                  "rows_evaluated": 0, "cache_hits": 0, "api_ms": 0.0,
                  "batches": 0, "errors": 0},
        "plans": {},
    }
S = GD["jev"]

def plan(name, sql, types):
    if name not in S["plans"]:
        S["plans"][name] = plpy.prepare(sql, types)
    return S["plans"][name]

def setting(name, default):
    r = plpy.execute(plan("cfg", "SELECT current_setting($1, true) AS v", ["text"]), ["jev." + name])
    v = r[0]["v"]
    return default if v in (None, "") else v

def api_key():
    k = setting("api_key", None) or os.environ.get("TYPESAFE_API_KEY")
    if not k:
        plpy.error("jev: no API key. SET jev.api_key = '...' or start the server with TYPESAFE_API_KEY set.")
    return k

model       = setting("model", "jev-latest")
batch_size  = max(1, int(setting("batch_size", "40")))
concurrency = max(1, int(setting("concurrency", "6")))
max_rows    = int(setting("max_prefetch_rows", "5000"))
notices     = setting("notices", "on").lower() in ("on", "true", "1", "yes")
api_url     = setting("api_url", "https://api.typesafe.ai/v1/systemone")
timeout     = float(setting("timeout", "90"))

# ---------------------------------------------------------------- question builders
opts = json.loads(options) if options else None

def build_question(i):
    ref = "rows[%d]" % i
    if kind == "noul":
        return {
            "type": "noul",
            "instructions": "Does the record `%s` satisfy the condition stated in `condition`?" % ref,
            "criteria": {
                "true": "The record satisfies the condition",
                "false": "The record does not satisfy the condition",
            },
        }
    if kind == "score":
        return {
            "type": "score",
            "instructions": "Rate the record `%s`: %s" % (ref, query),
            "criteria": opts,
        }
    if kind == "choice":
        return {
            "type": "choice",
            "instructions": "For the record `%s`: %s" % (ref, query),
            "criteria": {o: None for o in opts},
        }
    plpy.error("jev: unknown kind %r" % kind)

def state_for(rows):
    st = {"rows": rows}
    if kind == "noul":
        st = {"condition": query, "rows": rows}
    return st

# ---------------------------------------------------------------- HTTP (runs in threads: no plpy here)
def call_api(key, rows):
    body = json.dumps({
        "model": model,
        "state": state_for(rows),
        "questions": {("r%d" % i): build_question(i) for i in range(len(rows))},
    }).encode()
    delay = 0.5
    last = None
    for attempt in range(6):
        req = urllib.request.Request(api_url, data=body, method="POST", headers={
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
            "User-Agent": "pg-jev/0.1.0",
        })
        try:
            t0 = time.time()
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = json.loads(resp.read().decode())
            data["_ms"] = (time.time() - t0) * 1000
            return data
        except urllib.error.HTTPError as e:
            last = "%s %s" % (e.code, e.read().decode(errors="replace")[:300])
            if e.code in (429, 529) or e.code >= 500:
                time.sleep(delay); delay = min(delay * 2, 8); continue
            raise RuntimeError("jev: TypeSafe API error " + last)
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            last = str(e)
            time.sleep(delay); delay = min(delay * 2, 8)
    raise RuntimeError("jev: TypeSafe API unreachable after retries: " + str(last))

def evaluate(pairs):
    """pairs: list of (row_hash, row_text). Returns {row_hash: answer}. Fills stats."""
    key = api_key()
    batches = [pairs[i:i + batch_size] for i in range(0, len(pairs), batch_size)]
    out = {}
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=concurrency) as ex:
        results = list(ex.map(lambda b: call_api(key, [json.loads(t) for _, t in b]), batches))
    for b, data in zip(batches, results):
        st = S["stats"]
        st["requests"] += 1
        st["input_tokens"] += data.get("usage", {}).get("input_tokens", 0)
        st["output_tokens"] += data.get("usage", {}).get("output_tokens", 0)
        st["api_ms"] += data.get("_ms", 0)
        for i, (h, _) in enumerate(b):
            out[h] = data["answers"]["r%d" % i]
    S["stats"]["rows_evaluated"] += len(pairs)
    S["stats"]["batches"] += 1
    tokens = sum(d.get("usage", {}).get("input_tokens", 0) for d in results)
    return out, len(batches), tokens, (time.time() - t0) * 1000

# ---------------------------------------------------------------- main
cache_key = json.dumps([rel_type, query, kind, opts], sort_keys=True)
bucket = S["cache"].setdefault(cache_key, {})
row_hash = hashlib.sha1(row_json.encode()).hexdigest()

if row_hash in bucket:
    S["stats"]["cache_hits"] += 1
    return json.dumps(bucket[row_hash])

# Read-ahead: if this row comes from a real table, judge the whole table in one go.
regclass = plpy.execute(plan("regclass", "SELECT to_regclass($1)::text AS r", ["text"]), [rel_type])[0]["r"]
stmt_ts = plpy.execute(plan("ts", "SELECT statement_timestamp()::text AS t", []), [])[0]["t"]

if regclass and S["prefetched"].get(cache_key) != stmt_ts:
    S["prefetched"][cache_key] = stmt_ts
    rows = plpy.execute("SELECT to_jsonb(t)::text AS r FROM %s t" % regclass, max_rows)
    pending = {}
    for r in rows:
        h = hashlib.sha1(r["r"].encode()).hexdigest()
        if h not in bucket:
            pending[h] = r["r"]
    if row_hash not in bucket:
        pending[row_hash] = row_json
    if pending:
        try:
            answers, n_req, tokens, ms = evaluate(list(pending.items()))
        except RuntimeError as e:
            S["stats"]["errors"] += 1
            plpy.error(str(e))
        bucket.update(answers)
        if notices:
            plpy.notice("jev: %s → judged %d row%s of %s in %d request%s, %d input tokens (≈$%.4f), %.0f ms"
                        % (kind, len(pending), "" if len(pending) == 1 else "s", regclass,
                           n_req, "" if n_req == 1 else "s", tokens, tokens * USD_PER_INPUT_TOKEN, ms))
    if row_hash in bucket:
        return json.dumps(bucket[row_hash])

# Fallback: anonymous record (subquery/CTE) or a row that changed since read-ahead.
try:
    answers, _, tokens, ms = evaluate([(row_hash, row_json)])
except RuntimeError as e:
    S["stats"]["errors"] += 1
    plpy.error(str(e))
bucket.update(answers)
return json.dumps(bucket[row_hash])
$py$;

COMMENT ON FUNCTION _jev_eval(text, text, text, text, text) IS
  'Internal: evaluates one row (batched with its table) against a TypeSafe question. Returns the raw answer JSON.';

-- ------------------------------------------------------------------ public API

-- Full answer JSON for a row: {"type":"noul","noul":0.93} / score / choice answers.
CREATE FUNCTION jev_eval(rec anyelement, query text, kind text DEFAULT 'noul', options text[] DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT _jev_eval(pg_typeof($1)::text, to_jsonb($1)::text, $2, $3, to_json($4)::text)
$$;

-- Probability (0..1) that the row satisfies the natural-language condition.
CREATE FUNCTION jev_prob(rec anyelement, query text)
RETURNS float8 LANGUAGE sql STABLE AS $$
  SELECT (_jev_eval(pg_typeof($1)::text, to_jsonb($1)::text, $2, 'noul', NULL)->>'noul')::float8
$$;

-- Boolean predicate for WHERE clauses. Threshold: argument > jev.threshold setting > 0.5.
CREATE FUNCTION jev(rec anyelement, query text, threshold float8 DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT jev_prob($1, $2) >= coalesce($3, nullif(current_setting('jev.threshold', true), '')::float8, 0.5)
$$;

-- Graded rating along ordered levels; returns the probability-weighted level index (0 .. n-1).
CREATE FUNCTION jev_score(rec anyelement, query text, levels text[])
RETURNS float8 LANGUAGE sql STABLE AS $$
  SELECT (_jev_eval(pg_typeof($1)::text, to_jsonb($1)::text, $2, 'score', to_json($3)::text)->>'score')::float8
$$;

-- Same, normalised to 0..1 so it is comparable across rubrics.
CREATE FUNCTION jev_score_norm(rec anyelement, query text, levels text[])
RETURNS float8 LANGUAGE sql STABLE AS $$
  SELECT jev_score($1, $2, $3) / greatest(array_length($3, 1) - 1, 1)
$$;

-- Classify each row into one option.
CREATE FUNCTION jev_choice(rec anyelement, query text, options text[])
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT _jev_eval(pg_typeof($1)::text, to_jsonb($1)::text, $2, 'choice', to_json($3)::text)->>'choice'
$$;

-- Confidence (0..1) of the choice / score answer.
CREATE FUNCTION jev_confidence(rec anyelement, query text, kind text, options text[])
RETURNS float8 LANGUAGE sql STABLE AS $$
  SELECT (_jev_eval(pg_typeof($1)::text, to_jsonb($1)::text, $2, $3, to_json($4)::text)->>'confidence')::float8
$$;

-- Session statistics: requests, tokens, estimated cost, cache hits.
CREATE FUNCTION jev_stats()
RETURNS jsonb LANGUAGE plpython3u STABLE AS $py$
import json
s = {"requests": 0, "input_tokens": 0, "output_tokens": 0, "rows_evaluated": 0,
     "cache_hits": 0, "api_ms": 0.0, "batches": 0, "errors": 0}
s.update(GD.get("jev", {}).get("stats", {}))
s["estimated_cost_usd"] = round(s.get("input_tokens", 0) * 0.042 / 1_000_000, 6)
s["cached_answers"] = sum(len(b) for b in GD.get("jev", {}).get("cache", {}).values())
return json.dumps(s)
$py$;

-- Forget all cached judgments for this session.
CREATE FUNCTION jev_cache_clear()
RETURNS void LANGUAGE plpython3u VOLATILE AS $py$
if "jev" in GD:
    GD["jev"]["cache"].clear()
    GD["jev"]["prefetched"].clear()
$py$;

CREATE FUNCTION jev_version() RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT '0.1.0' $$;

COMMENT ON FUNCTION jev(anyelement, text, float8) IS 'True when the row satisfies the natural-language condition (TypeSafe Jev). Usage: WHERE jev(tbl, ''condition'')';
COMMENT ON FUNCTION jev_prob(anyelement, text) IS 'Probability that the row satisfies the natural-language condition.';
COMMENT ON FUNCTION jev_score(anyelement, text, text[]) IS 'Probability-weighted rating of the row along ordered levels.';
COMMENT ON FUNCTION jev_choice(anyelement, text, text[]) IS 'Classifies the row into one of the given options.';
