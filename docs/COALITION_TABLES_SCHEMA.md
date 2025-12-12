# Coalition Tables Schema Design

## Overview
Based on 42 API data analysis, we need two main tables:
1. **coalitions** — Coalition definitions (teams/groups)
2. **coalitions_users** — User membership in coalitions with scores/ranks

## Table 1: coalitions

### Purpose
Store coalition metadata—the teams/groups that users join.

### API Endpoint
- List: `/v2/coalitions?page=1&per_page=100`
- Single: `/v2/coalitions/:id`

### Fields (from sample data)

| Field | Type | PostgreSQL | Description | API Source | Example |
|-------|------|-----------|-------------|-----------|---------|
| `id` | Integer | BIGINT PRIMARY KEY | Coalition unique ID | `id` | `579` |
| `name` | String | VARCHAR(255) NOT NULL | Coalition display name | `name` | `"Al-Booma"` |
| `slug` | String | VARCHAR(255) UNIQUE | URL-friendly identifier | `slug` | `"al-booma"` |
| `image_url` | String | TEXT | Logo/image URL | `image_url` | `"https://cdn.intra.42.fr/coalition/image/579/booma.svg"` |
| `cover_url` | String | TEXT | Banner/cover background | `cover_url` | `"https://cdn.intra.42.fr/coalition/cover/579/green_background.jpg"` |
| `color` | String | VARCHAR(7) | Brand color (hex) | `color` | `"#2d5334"` |
| `score` | Integer | INTEGER DEFAULT 0 | Total coalition score | `score` | `0` or `1758` |
| `user_id` | Integer | BIGINT | Coalition founder/owner ID | `user_id` | `184604` |
| `created_at` | Timestamp | TIMESTAMP WITH TIME ZONE | Record creation | — | Auto-generated |
| `updated_at` | Timestamp | TIMESTAMP WITH TIME ZONE | Last update | — | Auto-generated |

### SQL Schema

```sql
CREATE TABLE IF NOT EXISTS coalitions (
  id BIGINT PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  slug VARCHAR(255) UNIQUE NOT NULL,
  image_url TEXT,
  cover_url TEXT,
  color VARCHAR(7),
  score INTEGER DEFAULT 0,
  user_id BIGINT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_coalitions_slug ON coalitions(slug);
CREATE INDEX idx_coalitions_user_id ON coalitions(user_id);
```

### Data Fill Strategy
- **Source**: `/v2/coalitions?per_page=100` (fetch all, likely 10-20 records max per campus)
- **Frequency**: Daily (as part of nightly_stable_tables.sh)
- **Scope**: Per-campus coalitions OR global coalitions (depending on API structure)
- **Expected Volume**: 10–50 per campus typically

---

## Table 2: coalitions_users

### Purpose
Track user membership in coalitions with score/rank (many-to-many relationship with scoring).

### API Endpoints
- By coalition: `/v2/coalitions/:id/coalitions_users?page=1&per_page=100`
- By user: `/v2/users/:id/coalitions_users?page=1&per_page=100`
- Active: `/v2/coalitions_users?coalition_id=:id&campus_id=:campus_id` (live leaderboard)

### Fields (from sample data)

| Field | Type | PostgreSQL | Description | API Source | Example |
|-------|------|-----------|-------------|-----------|---------|
| `id` | Integer | BIGINT PRIMARY KEY | Relation unique ID | `id` | `189826` |
| `coalition_id` | Integer | BIGINT NOT NULL | Coalition FK | `coalition_id` | `204` |
| `user_id` | Integer | BIGINT NOT NULL | User FK | `user_id` | `247783` |
| `score` | Integer | INTEGER DEFAULT 0 | User's score in coalition | `score` | `0` or `1758` |
| `rank` | Integer | INTEGER DEFAULT NULL | User's rank in coalition | `rank` | `88`, `1` |
| `campus_id` | Integer | BIGINT | Campus context (added for filtering) | — | (join from users table) |
| `created_at` | Timestamp | TIMESTAMP WITH TIME ZONE | When user joined | `created_at` | `"2025-10-27T09:26:12.717Z"` |
| `updated_at` | Timestamp | TIMESTAMP WITH TIME ZONE | Last score update | `updated_at` | `"2025-12-10T17:18:59.809Z"` |

### SQL Schema

```sql
CREATE TABLE IF NOT EXISTS coalitions_users (
  id BIGINT PRIMARY KEY,
  coalition_id BIGINT NOT NULL,
  user_id BIGINT NOT NULL,
  score INTEGER DEFAULT 0,
  rank INTEGER,
  campus_id BIGINT,
  created_at TIMESTAMP WITH TIME ZONE,
  updated_at TIMESTAMP WITH TIME ZONE,
  CONSTRAINT fk_coalitions_users_coalition
    FOREIGN KEY (coalition_id) REFERENCES coalitions(id) ON DELETE CASCADE,
  CONSTRAINT fk_coalitions_users_user
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE INDEX idx_coalitions_users_coalition_id ON coalitions_users(coalition_id);
CREATE INDEX idx_coalitions_users_user_id ON coalitions_users(user_id);
CREATE INDEX idx_coalitions_users_campus_id ON coalitions_users(campus_id);
CREATE UNIQUE INDEX idx_coalitions_users_unique ON coalitions_users(coalition_id, user_id);
```

### Data Fill Strategy
- **Source 1**: `/v2/coalitions/:id/coalitions_users` (per coalition, live scores)
- **Source 2**: `/v2/users/:id/coalitions_users` (per user, when syncing users)
- **Frequency**: 
  - **Live**: Real-time via live_db_sync.sh (30s rolling window)
  - **Daily**: Refresh all via nightly_stable_tables.sh or dedicated script
- **Scope**: Per-campus coalitions or global
- **Expected Volume**: 1000s of entries (all students × 1-4 coalitions per campus)

---

## Relationship Diagram

```
coalitions
  id (PK)
  ├─ user_id (founder) → users(id)
  └─ 1:M with coalitions_users

coalitions_users
  id (PK)
  ├─ coalition_id (FK) → coalitions(id)
  ├─ user_id (FK) → users(id)
  └─ campus_id → campuses(id)

users
  └─ 1:M with coalitions_users
```

---

## Data Fill Implementation

### Option A: Stable Tables (Daily Refresh)
Add to `nightly_stable_tables.sh`:
```bash
# Step 5: Update coalitions (per campus or global)
bash /srv/42_Network/repo/scripts/update_stable_tables/update_coalitions.sh

# Step 6: Update coalitions_users (leaderboard data)
bash /srv/42_Network/repo/scripts/update_stable_tables/update_coalitions_users.sh
```

### Option B: Live Sync (Real-time)
Extend `live_db_sync.sh`:
- Fetch each user's `/v2/users/:id/coalitions_users` during live sync
- Upsert into coalitions_users with updated score/rank
- Keep coalitions table updated via daily batch

### Option C: Hybrid (Recommended)
1. **Daily (01:00 UTC)**: Run update_coalitions.sh → update_coalitions_users.sh
2. **Live (30s)**: Fetch coalitions_users from active user detail endpoint
3. **Benefits**: Reference data stable, scoring always fresh

---

## Important Notes

### Data Availability
1. **Global vs Campus-Scoped**: 
   - Coalitions may be global (same 10 teams for all campuses)
   - OR campus-specific (different coalitions per campus)
   - Test endpoint to determine: `GET /v2/coalitions` vs `GET /v2/campus/:id/coalitions`

2. **Score Updates**:
   - Coalition `score` field = sum of all members' scores
   - User `score` field in coalitions_users = incremental updates
   - Rank = dynamic leaderboard position (updates frequently)

3. **Membership**:
   - Users typically join 1 coalition per campus
   - Some campuses may not have coalitions (check for empty lists)

### Performance Considerations
- **coalitions_users** table grows with student population
- Create indexes on: `coalition_id`, `user_id`, `campus_id`, `(coalition_id, user_id)`
- For leaderboards: Query `coalitions_users` with `ORDER BY rank` or `score DESC`

### API Rate Limits
- Fetching all students' coalitions_users: ~500ms per campus (pagination friendly)
- Best to batch by coalition or use the `/v2/coalitions_users` endpoint with filters

---

## Next Steps

1. **Verify API structure**: Test endpoints to confirm field availability
2. **Create table definitions**: Add CREATE TABLE statements to schema.sql
3. **Create update scripts**:
   - `update_coalitions.sh` — Fetch and upsert coalitions
   - `update_coalitions_users.sh` — Fetch and upsert user memberships + scores
4. **Integrate into pipeline**:
   - Add to `nightly_stable_tables.sh` for daily refresh
   - Optionally extend `live_db_sync.sh` for real-time scores
5. **Testing**: 
   - Verify data matches API responses
   - Test joinability with users/campuses for queries
   - Monitor score/rank update frequency

---

## Sample Queries (After Tables Populated)

```sql
-- Coalitions per campus
SELECT DISTINCT c.id, c.name, c.color
FROM coalitions c
JOIN coalitions_users cu ON c.id = cu.coalition_id
WHERE cu.campus_id = 12
ORDER BY c.name;

-- User's coalition rank at campus
SELECT c.name, cu.score, cu.rank
FROM coalitions_users cu
JOIN coalitions c ON cu.coalition_id = c.id
WHERE cu.user_id = 12345 AND cu.campus_id = 12;

-- Top 10 users in coalition
SELECT cu.rank, u.login, cu.score
FROM coalitions_users cu
JOIN users u ON cu.user_id = u.id
WHERE cu.coalition_id = 579
ORDER BY cu.rank
LIMIT 10;

-- Coalition leaderboard (top 5 per campus)
SELECT cu.coalition_id, c.name, cu.rank, u.login, cu.score
FROM coalitions_users cu
JOIN coalitions c ON cu.coalition_id = c.id
JOIN users u ON cu.user_id = u.id
WHERE cu.campus_id = 12 AND cu.rank <= 5
ORDER BY cu.coalition_id, cu.rank;
```
