-- Minimal schema: achievements, campuses, users (flattened into cursus_users), projects.

CREATE TABLE IF NOT EXISTS achievements (
  id             BIGINT PRIMARY KEY,
  name           TEXT,
  description    TEXT,
  tier           TEXT,
  kind           TEXT,
  visible        BOOLEAN,
  image          TEXT,
  nbr_of_success INTEGER,
  users_url      TEXT,
  parent_id      BIGINT,
  title          TEXT,
  ingested_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS campuses (
  id           BIGINT PRIMARY KEY,
  name         TEXT,
  time_zone    TEXT,
  language_id  BIGINT,
  language_name TEXT,
  language_identifier TEXT,
  users_count  INTEGER,
  vogsphere_id BIGINT,
  country      TEXT,
  address      TEXT,
  zip          TEXT,
  city         TEXT,
  website      TEXT,
  facebook     TEXT,
  twitter      TEXT,
  public       BOOLEAN,
  active       BOOLEAN,
  email_extension       TEXT,
  default_hidden_phone  BOOLEAN,
  ingested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_campuses_city ON campuses (city);
CREATE INDEX IF NOT EXISTS idx_campuses_active ON campuses (active);
CREATE INDEX IF NOT EXISTS idx_campuses_public ON campuses (public);

CREATE TABLE IF NOT EXISTS cursus (
  id          BIGINT PRIMARY KEY,
  name        TEXT,
  slug        TEXT,
  kind        TEXT,
  created_at  TIMESTAMPTZ,
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cursus_slug ON cursus (slug);

CREATE TABLE IF NOT EXISTS cursus_users (
  id           BIGINT PRIMARY KEY,
  cursus_id    BIGINT NOT NULL,
  campus_id    BIGINT,
  user_id      BIGINT NOT NULL,
  user_email   TEXT,
  user_login   TEXT,
  user_first_name TEXT,
  user_last_name  TEXT,
  user_usual_full_name  TEXT,
  user_usual_first_name TEXT,
  user_phone   TEXT,
  user_displayname TEXT,
  user_kind    TEXT,
  user_image_link TEXT,
  user_image_large TEXT,
  user_image_medium TEXT,
  user_image_small TEXT,
  user_image_micro TEXT,
  user_image   JSONB,
  user_staff   BOOLEAN,
  user_correction_point INTEGER,
  user_pool_month TEXT,
  user_pool_year  TEXT,
  user_location   TEXT,
  user_wallet     INTEGER,
  user_anonymize_date TIMESTAMPTZ,
  user_data_erasure_date TIMESTAMPTZ,
  user_created_at TIMESTAMPTZ,
  user_updated_at TIMESTAMPTZ,
  user_alumnized_at TIMESTAMPTZ,
  user_alumni   BOOLEAN,
  user_active   BOOLEAN,
  grade        TEXT,
  level        NUMERIC,
  begin_at     TIMESTAMPTZ,
  end_at       TIMESTAMPTZ,
  blackholed_at TIMESTAMPTZ,
  has_coalition BOOLEAN,
  skills       JSONB,
  created_at   TIMESTAMPTZ,
  updated_at   TIMESTAMPTZ,
  ingested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cursus_users_cursus_id ON cursus_users (cursus_id);
CREATE INDEX IF NOT EXISTS idx_cursus_users_user_id ON cursus_users (user_id);

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

-- Project sessions (per campus/cursus)
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

-- Linker: which campuses offer which projects
CREATE TABLE IF NOT EXISTS campus_projects (
  campus_id     BIGINT NOT NULL,
  project_id    BIGINT NOT NULL,
  ingested_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (campus_id, project_id)
);

CREATE INDEX IF NOT EXISTS idx_campus_projects_project ON campus_projects (project_id);

-- Linker: which achievements are available at which campus
CREATE TABLE IF NOT EXISTS campus_achievements (
  campus_id       BIGINT NOT NULL,
  achievement_id  BIGINT NOT NULL,
  ingested_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (campus_id, achievement_id)
);

CREATE INDEX IF NOT EXISTS idx_campus_achievements_achievement ON campus_achievements (achievement_id);
