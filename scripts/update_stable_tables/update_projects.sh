#!/bin/bash
set -euo pipefail

# Fetch all projects and upsert into Postgres.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$ROOT_DIR/scripts/helpers/fetch_cursus_projects.sh"
EXPORT_DIR="$ROOT_DIR/exports/05_projects"
RAW_JSON="$EXPORT_DIR/raw_all.json"
NORMALIZED_JSON="$EXPORT_DIR/all.json"
SESSION_EXPORT_DIR="$ROOT_DIR/exports/07_project_sessions"
SESSION_ALL_FILE="$SESSION_EXPORT_DIR/all.json"
CAMPUS_EXPORT_DIR="$ROOT_DIR/exports/06_campus_projects"
CAMPUS_ALL_FILE="$CAMPUS_EXPORT_DIR/all.json"
CURSUS_ID=${CURSUS_ID:-21}

mkdir -p "$EXPORT_DIR"
mkdir -p "$SESSION_EXPORT_DIR"
mkdir -p "$CAMPUS_EXPORT_DIR"

if [[ -f "$ROOT_DIR/../.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/../.env"
fi

DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-5432}
DB_NAME=${DB_NAME:-api42}
DB_USER=${DB_USER:-api42}
DB_PASSWORD=${DB_PASSWORD:-api42}
export PGOPTIONS="${PGOPTIONS:--c client_min_messages=warning}"
PSQL_CONN="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
export PGPASSWORD="$DB_PASSWORD"

# Ensure token is fresh before starting API calls
"$ROOT_DIR/scripts/token_manager.sh" ensure-fresh >&2

if [[ ! -x "$HELPER" ]]; then
  echo "Helper script not found or not executable: $HELPER" >&2
  exit 1
fi

echo "Fetching projects..."
set +e
CURSUS_ID="$CURSUS_ID" "$HELPER" "$@"
helper_status=$?
set -e
if [[ $helper_status -eq 3 ]]; then
  echo "Using cached projects fetch (skip due to recency)."
elif [[ $helper_status -ne 0 ]]; then
  exit $helper_status
fi

if [[ ! -s "$RAW_JSON" ]]; then
  echo "No projects data found at $RAW_JSON" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

run_psql() {
  if command -v psql >/dev/null 2>&1; then
    psql "$PSQL_CONN" "$@"
  elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose exec -T -e PGPASSWORD="$DB_PASSWORD" db psql -h db -U "$DB_USER" -d "$DB_NAME" "$@"
  else
    echo "psql is not available locally and docker compose is unavailable." >&2
    exit 1
  fi
}

echo "Building project_sessions export..."
jq '[ .[] as $p | $p.project_sessions[]? | (.project_id //= ($p.id // .project.id // null)) ]' "$RAW_JSON" > "$SESSION_ALL_FILE"
session_count=$(jq 'length' "$SESSION_ALL_FILE")
session_ts=$(date +%s)

echo "Building campus_projects export..."
# Only include links to active+public campuses (filter against campuses file)
jq --slurpfile campuses "$ROOT_DIR/exports/02_campus/all.json" '
  ([$campuses[] | .[] | select(.active == true and .public == true) | .id] | unique) as $active_ids |
  [ .[] as $p | $p.campus[]? | select(.id | IN($active_ids[])) | {campus_id: (.id // null), project_id: $p.id} ]
' "$RAW_JSON" > "$CAMPUS_ALL_FILE"
campus_link_count=$(jq 'length' "$CAMPUS_ALL_FILE")

echo "Building normalized projects export..."
jq '
  [ .[] as $p |
    { id: $p.id,
      name: $p.name,
      slug: $p.slug,
      parent_id: ($p.parent_id // $p.parent.id // null),
      difficulty: ($p.difficulty // null),
      exam: ($p.exam // null),
      git_id: ($p.git_id // null),
      repository: ($p.repository // null),
      recommendation: ($p.recommendation // null),
      created_at: ($p.created_at // null),
      updated_at: ($p.updated_at // null)
    }
  ] as $projects
  |
  [ .[] | select(.parent != null) |
    { id: .parent.id,
      name: .parent.name,
      slug: .parent.slug,
      parent_id: null,
      difficulty: null,
      exam: null,
      git_id: null,
      repository: null,
      recommendation: null,
      created_at: null,
      updated_at: null
    }
  ] as $parents
  |
  ($projects + $parents)
  | group_by(.id)
  | map(.[0] | del(.raw_json))
' "$RAW_JSON" > "$NORMALIZED_JSON"

run_psql <<'SQL'
CREATE TABLE IF NOT EXISTS projects (
  id          BIGINT PRIMARY KEY,
  name        TEXT,
  slug        TEXT,
  parent_id   BIGINT,
  difficulty  INTEGER,
  exam        BOOLEAN,
  git_id      BIGINT,
  repository  TEXT,
  recommendation TEXT,
  created_at  TIMESTAMPTZ,
  updated_at  TIMESTAMPTZ,
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_projects_slug ON projects (slug);
CREATE INDEX IF NOT EXISTS idx_projects_parent_id ON projects (parent_id);
ALTER TABLE projects
  ADD COLUMN IF NOT EXISTS difficulty  INTEGER,
  ADD COLUMN IF NOT EXISTS exam        BOOLEAN,
  ADD COLUMN IF NOT EXISTS git_id      BIGINT,
  ADD COLUMN IF NOT EXISTS repository  TEXT,
  ADD COLUMN IF NOT EXISTS recommendation TEXT,
  ADD COLUMN IF NOT EXISTS created_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS updated_at  TIMESTAMPTZ;
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'projects' AND column_name = 'raw_json'
  ) THEN
    EXECUTE 'ALTER TABLE projects DROP COLUMN raw_json';
  END IF;
END$$;
CREATE TABLE IF NOT EXISTS campus_projects (
  campus_id     BIGINT NOT NULL,
  project_id    BIGINT NOT NULL,
  ingested_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (campus_id, project_id)
);
CREATE INDEX IF NOT EXISTS idx_campus_projects_project ON campus_projects (project_id);
CREATE TABLE IF NOT EXISTS project_sessions (
  id                      BIGINT PRIMARY KEY,
  project_id              BIGINT NOT NULL,
  campus_id               BIGINT,
  cursus_id               BIGINT,
  begin_at                TIMESTAMPTZ,
  end_at                  TIMESTAMPTZ,
  difficulty              INTEGER,
  estimate_time           TEXT,
  exam                    BOOLEAN,
  marked                  BOOLEAN,
  max_project_submissions INTEGER,
  max_people              INTEGER,
  duration_days           INTEGER,
  commit                  TEXT,
  description             TEXT,
  is_subscriptable        BOOLEAN,
  objectives              JSONB,
  scales                  JSONB,
  terminating_after       TEXT,
  uploads                 JSONB,
  solo                    BOOLEAN,
  team_behaviour          TEXT,
  created_at              TIMESTAMPTZ,
  updated_at              TIMESTAMPTZ,
  ingested_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_project_sessions_project_id ON project_sessions (project_id);
CREATE INDEX IF NOT EXISTS idx_project_sessions_campus_id ON project_sessions (campus_id);
CREATE INDEX IF NOT EXISTS idx_project_sessions_cursus_id ON project_sessions (cursus_id);
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'project_sessions' AND column_name = 'estimated_time'
  ) THEN
    EXECUTE 'ALTER TABLE project_sessions RENAME COLUMN estimated_time TO estimate_time';
  END IF;
END$$;
ALTER TABLE project_sessions
  ADD COLUMN IF NOT EXISTS max_people              INTEGER,
  ADD COLUMN IF NOT EXISTS duration_days           INTEGER,
  ADD COLUMN IF NOT EXISTS commit                  TEXT,
  ADD COLUMN IF NOT EXISTS description             TEXT,
  ADD COLUMN IF NOT EXISTS is_subscriptable        BOOLEAN,
  ADD COLUMN IF NOT EXISTS objectives              JSONB,
  ADD COLUMN IF NOT EXISTS scales                  JSONB,
  ADD COLUMN IF NOT EXISTS terminating_after       TEXT,
  ADD COLUMN IF NOT EXISTS uploads                 JSONB;
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'campus_projects' AND column_name = 'raw_json'
  ) THEN
    EXECUTE 'ALTER TABLE campus_projects DROP COLUMN raw_json';
  END IF;
END$$;
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'project_sessions' AND column_name = 'raw_json'
  ) THEN
    EXECUTE 'ALTER TABLE project_sessions DROP COLUMN raw_json';
  END IF;
END$$;

DROP TABLE IF EXISTS projects_delta;
CREATE TABLE projects_delta (LIKE projects INCLUDING DEFAULTS);
TRUNCATE projects_delta;
DROP TABLE IF EXISTS campus_projects_delta;
CREATE TABLE campus_projects_delta (
  campus_id   BIGINT NOT NULL,
  project_id  BIGINT NOT NULL,
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (campus_id, project_id)
);
TRUNCATE campus_projects_delta;
DROP TABLE IF EXISTS project_sessions_delta;
CREATE TABLE project_sessions_delta (LIKE project_sessions INCLUDING DEFAULTS);
TRUNCATE project_sessions_delta;
SQL

echo "Staging into projects_delta..."
jq -r '.[] | [
  .id,
  .name,
  .slug,
  (.parent_id // null),
  (.difficulty // null),
  (.exam // null),
  (.git_id // null),
  (.repository // null),
  (.recommendation // null),
  (.created_at // null),
  (.updated_at // null)
] | @csv' "$NORMALIZED_JSON" \
  | run_psql -c "\copy projects_delta (id,name,slug,parent_id,difficulty,exam,git_id,repository,recommendation,created_at,updated_at) FROM STDIN WITH (FORMAT csv, NULL '')"

echo "Staging campus_projects..."
jq -r '.[] | [
  .campus_id,
  .project_id
] | @csv' "$CAMPUS_ALL_FILE" \
  | run_psql -c "\copy campus_projects_delta (campus_id,project_id) FROM STDIN WITH (FORMAT csv, NULL '')"

echo "Staging project_sessions..."
jq -r '.[] as $p | $p.project_sessions[]? | [
  .id,
  (.project.id // $p.id // null),
  (.campus_id // null),
  (.cursus_id // null),
  (.begin_at // null),
  (.end_at // null),
  (.difficulty // null),
  (.estimate_time // null),
  (.exam // null),
  (.marked // null),
  (.max_project_submissions // null),
  (.max_people // null),
  (.duration_days // null),
  (.commit // null),
  (.description // null),
  (.is_subscriptable // null),
  (.objectives // null | tojson),
  (.scales // null | tojson),
  (.terminating_after // null),
  (.uploads // null | tojson),
  (.solo // null),
  (.team_behaviour // null),
  (.created_at // null),
  (.updated_at // null)
] | @csv' "$RAW_JSON" \
  | run_psql -c "\copy project_sessions_delta (id,project_id,campus_id,cursus_id,begin_at,end_at,difficulty,estimate_time,exam,marked,max_project_submissions,max_people,duration_days,commit,description,is_subscriptable,objectives,scales,terminating_after,uploads,solo,team_behaviour,created_at,updated_at) FROM STDIN WITH (FORMAT csv, NULL '')"

delta_count=$(run_psql -t -c "SELECT COUNT(*) FROM projects_delta")
if [ "$delta_count" = "0" ]; then
  echo "Skip upsert: No changes in projects_delta (using cached data)"
  exit 0
fi

echo "Pruning projects missing from this snapshot..."
run_psql <<'SQL'
DELETE FROM projects p
WHERE NOT EXISTS (SELECT 1 FROM projects_delta d WHERE d.id = p.id);
SQL

echo "Upserting projects..."
run_psql <<'SQL'
WITH upsert AS (
INSERT INTO projects (id,name,slug,parent_id,difficulty,exam,git_id,repository,recommendation,created_at,updated_at)
SELECT id,name,slug,parent_id,difficulty,exam,git_id,repository,recommendation,created_at,updated_at FROM projects_delta
ON CONFLICT (id) DO UPDATE SET
  name=EXCLUDED.name,
  slug=EXCLUDED.slug,
  parent_id=EXCLUDED.parent_id,
  difficulty=EXCLUDED.difficulty,
  exam=EXCLUDED.exam,
  git_id=EXCLUDED.git_id,
  repository=EXCLUDED.repository,
  recommendation=EXCLUDED.recommendation,
  created_at=EXCLUDED.created_at,
  updated_at=EXCLUDED.updated_at,
  ingested_at=EXCLUDED.ingested_at
  RETURNING xmax = 0 AS inserted
)
SELECT
  SUM(CASE WHEN inserted THEN 1 ELSE 0 END) AS inserted,
  SUM(CASE WHEN NOT inserted THEN 1 ELSE 0 END) AS updated
FROM upsert;
TRUNCATE projects_delta;
SQL

echo "Syncing campus_projects..."
run_psql <<'SQL'
-- Delete campus_projects links for campuses NOT in the active campus list
DELETE FROM campus_projects cp
WHERE cp.campus_id NOT IN (SELECT DISTINCT id FROM campuses);

-- Delete old links for projects that have been updated
DELETE FROM campus_projects cp
WHERE EXISTS (
  SELECT 1 FROM projects_delta pd
  WHERE pd.id = cp.project_id
    AND NOT EXISTS (
      SELECT 1 FROM campus_projects_delta d
      WHERE d.campus_id = cp.campus_id AND d.project_id = cp.project_id
    )
);

INSERT INTO campus_projects (campus_id, project_id, ingested_at)
SELECT campus_id, project_id, ingested_at FROM campus_projects_delta
ON CONFLICT (campus_id, project_id) DO UPDATE SET
  ingested_at = EXCLUDED.ingested_at;

-- Remove projects that have no active campus links
DELETE FROM projects p
WHERE NOT EXISTS (
  SELECT 1 FROM campus_projects cp WHERE cp.project_id = p.id
);

TRUNCATE campus_projects_delta;

INSERT INTO project_sessions (id,project_id,campus_id,cursus_id,begin_at,end_at,difficulty,estimate_time,exam,marked,max_project_submissions,max_people,duration_days,commit,description,is_subscriptable,objectives,scales,terminating_after,uploads,solo,team_behaviour,created_at,updated_at,ingested_at)
SELECT id,project_id,campus_id,cursus_id,begin_at,end_at,difficulty,estimate_time,exam,marked,max_project_submissions,max_people,duration_days,commit,description,is_subscriptable,objectives,scales,terminating_after,uploads,solo,team_behaviour,created_at,updated_at,ingested_at FROM project_sessions_delta
ON CONFLICT (id) DO UPDATE SET
  project_id=EXCLUDED.project_id,
  campus_id=EXCLUDED.campus_id,
  cursus_id=EXCLUDED.cursus_id,
  begin_at=EXCLUDED.begin_at,
  end_at=EXCLUDED.end_at,
  difficulty=EXCLUDED.difficulty,
  estimate_time=EXCLUDED.estimate_time,
  exam=EXCLUDED.exam,
  marked=EXCLUDED.marked,
  max_project_submissions=EXCLUDED.max_project_submissions,
  max_people=EXCLUDED.max_people,
  duration_days=EXCLUDED.duration_days,
  commit=EXCLUDED.commit,
  description=EXCLUDED.description,
  is_subscriptable=EXCLUDED.is_subscriptable,
  objectives=EXCLUDED.objectives,
  scales=EXCLUDED.scales,
  terminating_after=EXCLUDED.terminating_after,
  uploads=EXCLUDED.uploads,
  solo=EXCLUDED.solo,
  team_behaviour=EXCLUDED.team_behaviour,
  created_at=EXCLUDED.created_at,
  updated_at=EXCLUDED.updated_at,
  ingested_at=EXCLUDED.ingested_at;

-- Delete project_sessions for projects without active campus links
DELETE FROM project_sessions ps
WHERE NOT EXISTS (
  SELECT 1 FROM projects p WHERE p.id = ps.project_id
);

TRUNCATE project_sessions_delta;
SQL

echo "Projects sync complete."

proj_total=$(run_psql -Atc "SELECT count(*) FROM projects;")
proj_recent=$(run_psql -Atc "SELECT count(*) FROM projects WHERE ingested_at >= now() - interval '1 minute';")
campus_proj_total=$(run_psql -Atc "SELECT count(*) FROM campus_projects;")
campus_proj_recent=$(run_psql -Atc "SELECT count(*) FROM campus_projects WHERE ingested_at >= now() - interval '1 minute';")
sess_total=$(run_psql -Atc "SELECT count(*) FROM project_sessions;")
sess_recent=$(run_psql -Atc "SELECT count(*) FROM project_sessions WHERE ingested_at >= now() - interval '1 minute';")
echo "Projects: total=$proj_total, recently_ingested=$proj_recent"
echo "Campus projects: total=$campus_proj_total, recently_ingested=$campus_proj_recent"
echo "Project sessions: total=$sess_total, recently_ingested=$sess_recent"

# Cleanup: remove page files, keep only all.json and raw_all.json
rm -f "$EXPORT_DIR"/page_*.json "$EXPORT_DIR"/raw_page_*.json
