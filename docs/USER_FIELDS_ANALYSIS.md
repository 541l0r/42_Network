# 42 Network User Fields Analysis

## Overview
The database tracks student activity, engagement metrics, and learning outcomes. Here's what each field means:

---

## 📋 Identity Fields

### `id` (BIGINT, PRIMARY KEY)
- **Unique identifier** for each user in the 42 network
- Assigned when account is created
- **Example**: 233627 = taeheo
- **Use**: Primary key for all references

### `login` (TEXT, INDEXED)
- **Username** - the handle students use to log in
- Usually firstname + optional letter (e.g., "taeheo", "hyokim")
- **Example**: `taeheo`, `hyokim`, `gyun`
- **Use**: Human-readable identifier, search index

### `email` (TEXT, INDEXED)
- **Student email address** - follows pattern: `login@student.42{campus}.{country}`
- **Examples**:
  - `taeheo@student.42gyeongsan.kr` (South Korea campus)
  - `user@student.42paris.fr` (Paris campus)
- **Use**: Contact info, account recovery, email notifications

### `first_name` / `last_name` / `usual_full_name` / `usual_first_name` (TEXT)
- **Legal/display names** for students
- May differ from login (e.g., login is "taeheo" but name is "Tae Heo")
- **Use**: Formal communications, certificates, diplomas

### `displayname` (TEXT)
- **Nickname or display name** for community profiles
- May be different from legal name
- **Use**: User-facing displays, forums, chat

### `url` (TEXT)
- **Profile URL** - link to their 42 portal profile
- **Example**: `https://profile.intra.42.fr/users/taeheo`

### `phone` (TEXT)
- **Contact phone number**
- Usually empty unless provided during registration

---

## 🎓 Educational Status

### `kind` (TEXT, INDEXED)
- **User type** - determines role and permissions
- **Values**:
  - `student` - Normal learner in the curriculum
  - `staff` - 42 staff member (teacher, mentor, admin)
  - `alumni` - Graduated student
  - `external` - Non-42 user (if applicable)
- **Use**: Filter active students, distinguish staff, track alumni

### `campus_id` (BIGINT, INDEXED, FK)
- **Campus assignment** - which 42 school location
- **Examples**:
  - 1 = 42 Paris
  - 12 = 42 Gyeongsan (Korea)
  - 69 = 42 Gyeongsan (based on sample data)
  - 20+ = Various international campuses
- **Use**: Geographic filtering, campus-specific reports

### `active` (BOOLEAN, INDEXED)
- **Currently logged in / connected to campus network**
- `true` = Student is currently online/connected
- `false` or **NULL** = Student is offline (NULL treated as false)
- **Real-world meaning**: Whether student is currently working on campus
- **Use**: Real-time presence tracking (who's online right now?)

### `alumni` (BOOLEAN)
- **Graduation status**
- `true` = Has completed the curriculum
- `false` = Still in school or dropped out
- **Use**: Identify graduates, career tracking

### `staff` (BOOLEAN)
- **Is this user a 42 staff member?**
- `true` = Teacher, mentor, or admin
- `false` = Student or external
- **Use**: Access control, staff reports

---

## 💰 Engagement & Progress Metrics

### `wallet` (INTEGER)
- **Currency balance** - points awarded for completing projects/activities
- Starts at 0, increases as student completes work
- Can be spent on perks (snacks, tutoring, etc.)
- **Real-world meaning**: 
  - Reflects **work output** - how many projects completed
  - Higher wallet = more productive student
- **Example data**:
  - taeheo: 0 (new or inactive)
  - minseobk: 5 (moderate activity)
  - User with 500+ = highly productive
- **Use**: Gamification, motivation tracking, resource allocation

### `correction_point` (INTEGER)
- **Peer review points** - earned by reviewing other students' work
- Students earn points by evaluating peers' submissions
- Can be used as alternative currency
- **Real-world meaning**:
  - Reflects **community engagement** - how helpful/active
  - Shows willingness to help peers improve
- **Example data**:
  - gyun: 9 (good community member)
  - minseobk: 2 (minimal peer review)
  - User with 20+ = very engaged mentor
- **Use**: Identify mentors, track collaboration culture

---

## 📍 Location & Status

### `location` (TEXT)
- **Current physical location in campus**
- Cluster/room/seat notation (e.g., `c1r9s3`)
  - `c1` = Cluster 1
  - `r9` = Row 9
  - `s3` = Seat 3
- **Empty** = At home/remote or not logged in
- **Example data**:
  - `c1r9s3` = Student at desk in cluster 1
  - `c1r4s6` = Different desk location
  - Empty = Currently offline/working remotely
- **Use**: Space utilization, study patterns, capacity planning

### `updated_at` (TIMESTAMP WITH TIMEZONE)
- **Last API update time** - when this user's data was last refreshed from 42 API
- Doesn't necessarily mean the user was active
- Just means 42 API reported an update (could be server-side)
- **Example**:
  - `2025-12-11 12:44:47.845+00` = Data refreshed Dec 11 at 12:44 UTC
- **Use**: Data freshness tracking, sync auditing

### `ingested_at` (TIMESTAMP WITH TIMEZONE, NOT NULL, DEFAULT NOW())
- **When we stored this data in our DB**
- Automatically set to current timestamp on insert
- Tracks our data pipeline freshness
- **Use**: Monitor sync lag, data quality

---

## 📅 Cohort & Pool Information

### `pool_month` (TEXT)
- **Cohort month** - when the student started/will start
- Typically coincides with campus intake periods
- **Examples**: `july`, `january`, `september`
- **Use**: Cohort grouping, progression tracking

### `pool_year` (TEXT)
- **Cohort year** - when student started
- **Examples**: `2025`, `2024`, `2023`
- **Use**: Batch tracking, graduation projections

**Combined meaning**: A student with `pool_month=july` + `pool_year=2025` started in July 2025 cohort

---

## ⚠️ Account Lifecycle

### `created_at` (TIMESTAMP WITH TIMEZONE)
- **Account creation date**
- When user first registered with 42
- **Use**: Calculate account age, onboarding metrics

### `anonymize_date` (TIMESTAMP WITH TIMEZONE)
- **When account was anonymized**
- Privacy protection - removes personal identifiers
- Non-null = Account anonymized (for GDPR compliance)
- **Use**: Privacy compliance tracking

### `data_erasure_date` (TIMESTAMP WITH TIMEZONE)
- **When account data was erased**
- Complete data removal (right to be forgotten)
- Non-null = Account data deleted
- **Use**: Deletion audit trails, compliance

### `alumnized_at` (TIMESTAMP WITH TIMEZONE)
- **When student graduated/completed**
- Marks transition to alumni status
- **Use**: Graduation reporting, career tracking

---

## 🖼️ Profile Images

### `image_link`, `image_large`, `image_medium`, `image_small`, `image_micro` (TEXT)
- **Profile photo URLs** in different resolutions
- Cached from 42 API for faster loading
- **Use**: User avatars, profile displays

### `image` (JSONB)
- **Raw image metadata** from 42 API
- Stores original response as JSON
- **Use**: Full metadata access, migration purposes

---

## 📊 Real-Time Monitoring Fields

### What changes frequently (tracked by live_db_sync):
1. **`wallet`** - Increases when projects completed
2. **`correction_point`** - Increases when peer reviews done
3. **`location`** - Changes when student moves around campus
4. **`active?`** - Reflects current login/connection status (changes frequently)
5. **`updated_at`** - Changes on any API data refresh

### What rarely changes:
- `id`, `login`, `email`, `kind`, `campus_id` (immutable identifiers)
- `first_name`, `last_name` (legal names)
- `created_at`, `alumnized_at` (lifecycle events)

---

## 💡 Key Insights from Current Data

### Sample Students (from live data):
```
taeheo:      wallet=0,   cp=8,  location=empty  (online, not using points)
hyokim:      wallet=0,   cp=7,  location=c1r9s3 (at desk, engaged reviews)
minseobk:    wallet=5,   cp=2,  location=empty  (completed some work)
jaeminle:    wallet=2,   cp=3,  location=c1r4s6 (at desk, new student)
```

### Interpretation:
- **Active location tracking** = Students onsite in campus
- **Wallet=0, CP>5** = Peer review focused, community engaged
- **Wallet>10, CP>10** = High productivity, mentor-level
- **Wallet=0, CP=0** = New student or inactive

---

## 🔄 Live Sync Context

The live_db_sync updates **only meaningful fields**:
- ✅ `wallet` - Real progress indicator
- ✅ `correction_point` - Engagement metric  
- ✅ `location` - Presence tracking
- ✅ `active` - Enrollment status
- ✅ `campus_id` - Organizational change
- ✅ `updated_at` - Data freshness

It **ignores** fields that don't change in real-time (name, email, etc.)

---

## 📈 What You Can Track

With this comprehensive database, you can monitor:

1. **Individual Student Progress**
   - Wallet growth → projects completed
   - Correction points → peer mentoring activity
   - Location history → campus presence patterns

2. **Cohort Performance**
   - Pool groups → track cohorts through curriculum
   - Graduation (alumni=true) → completion rates
   - Login status (active?) → real-time presence detection

3. **Campus Utilization**
   - Location tracking → desk/cluster usage
   - Real-time presence → capacity planning

4. **Community Health**
   - Correction point distribution → mentoring culture
   - Wallet vs CP ratio → balance of work vs community

5. **Data Quality**
   - `updated_at` vs `ingested_at` → sync lag
   - Fresh data freshness → API reliability
