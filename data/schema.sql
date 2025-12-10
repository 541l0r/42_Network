-- Base schema for 42 Network data ingestion

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
  raw_json       JSONB,
  ingested_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS achievements_users (
  id             BIGINT PRIMARY KEY,
  achievement_id BIGINT NOT NULL,
  user_id        BIGINT NOT NULL,
  created_at     TIMESTAMPTZ,
  updated_at     TIMESTAMPTZ,
  raw_json       JSONB,
  ingested_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_achievements_users_achievement_id ON achievements_users (achievement_id);
CREATE INDEX IF NOT EXISTS idx_achievements_users_user_id ON achievements_users (user_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_achievements_users_pair ON achievements_users (achievement_id, user_id);

CREATE TABLE IF NOT EXISTS campuses (
  id           BIGINT PRIMARY KEY,
  name         TEXT,
  time_zone    TEXT,
  language     JSONB,
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
  raw_json     JSONB,
  ingested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_campuses_city ON campuses (city);
CREATE INDEX IF NOT EXISTS idx_campuses_active ON campuses (active);
CREATE INDEX IF NOT EXISTS idx_campuses_public ON campuses (public);

CREATE TABLE IF NOT EXISTS users (
  id                BIGINT PRIMARY KEY,
  email             TEXT,
  login             TEXT,
  first_name        TEXT,
  last_name         TEXT,
  usual_full_name   TEXT,
  usual_first_name  TEXT,
  url               TEXT,
  phone             TEXT,
  displayname       TEXT,
  kind              TEXT,
  image             JSONB,
  staff             BOOLEAN,
  correction_point  INTEGER,
  pool_month        TEXT,
  pool_year         TEXT,
  location          TEXT,
  wallet            INTEGER,
  anonymize_date    TIMESTAMPTZ,
  data_erasure_date TIMESTAMPTZ,
  created_at        TIMESTAMPTZ,
  updated_at        TIMESTAMPTZ,
  alumnized_at      TIMESTAMPTZ,
  alumni            BOOLEAN,
  active            BOOLEAN,
  raw_json          JSONB,
  ingested_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_login ON users (login);
CREATE INDEX IF NOT EXISTS idx_users_active ON users (active);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_achievements_users_achievement'
  ) THEN
    ALTER TABLE achievements_users
      ADD CONSTRAINT fk_achievements_users_achievement
      FOREIGN KEY (achievement_id) REFERENCES achievements (id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_achievements_users_user'
  ) THEN
    ALTER TABLE achievements_users
      ADD CONSTRAINT fk_achievements_users_user
      FOREIGN KEY (user_id) REFERENCES users (id);
  END IF;
END$$;

CREATE TABLE IF NOT EXISTS cursus (
  id          BIGINT PRIMARY KEY,
  name        TEXT,
  slug        TEXT,
  kind        TEXT,
  created_at  TIMESTAMPTZ,
  raw_json    JSONB,
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cursus_slug ON cursus (slug);

CREATE TABLE IF NOT EXISTS cursus_users (
  id           BIGINT PRIMARY KEY,
  cursus_id    BIGINT NOT NULL,
  user_id      BIGINT NOT NULL,
  grade        TEXT,
  level        NUMERIC,
  begin_at     TIMESTAMPTZ,
  end_at       TIMESTAMPTZ,
  created_at   TIMESTAMPTZ,
  updated_at   TIMESTAMPTZ,
  raw_json     JSONB,
  ingested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cursus_users_cursus_id ON cursus_users (cursus_id);
CREATE INDEX IF NOT EXISTS idx_cursus_users_user_id ON cursus_users (user_id);

CREATE TABLE IF NOT EXISTS projects (
  id          BIGINT PRIMARY KEY,
  name        TEXT,
  slug        TEXT,
  parent_id   BIGINT,
  raw_json    JSONB,
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_projects_slug ON projects (slug);

CREATE TABLE IF NOT EXISTS projects_users (
  id           BIGINT PRIMARY KEY,
  project_id   BIGINT NOT NULL,
  user_id      BIGINT NOT NULL,
  status       TEXT,
  final_mark   INTEGER,
  validated    BOOLEAN,
  occurrence   INTEGER,
  marked_at    TIMESTAMPTZ,
  created_at   TIMESTAMPTZ,
  updated_at   TIMESTAMPTZ,
  raw_json     JSONB,
  ingested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_projects_users_project_id ON projects_users (project_id);
CREATE INDEX IF NOT EXISTS idx_projects_users_user_id ON projects_users (user_id);

CREATE TABLE IF NOT EXISTS locations (
  id           BIGINT PRIMARY KEY,
  user_id      BIGINT NOT NULL,
  campus_id    BIGINT,
  begin_at     TIMESTAMPTZ,
  end_at       TIMESTAMPTZ,
  host         TEXT,
  primary_flag BOOLEAN,
  created_at   TIMESTAMPTZ,
  updated_at   TIMESTAMPTZ,
  raw_json     JSONB,
  ingested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_locations_user_id ON locations (user_id);
CREATE INDEX IF NOT EXISTS idx_locations_campus_id ON locations (campus_id);
CREATE INDEX IF NOT EXISTS idx_locations_begin_at ON locations (begin_at);
