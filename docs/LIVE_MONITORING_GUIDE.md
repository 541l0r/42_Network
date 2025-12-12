# Live Monitoring Quick Reference

## What Each Monitored Field Means in Real-Time

### 💰 Wallet Changes
**Meaning**: Student completed a project or evaluation
```
✏️ UPDATED: hyokim (ID: 197399)
   💰 Wallet: 20 → 25
```
→ They just earned 5 points (completed coursework/activity)

### ⭐ Correction Point (CP) Changes  
**Meaning**: Student reviewed and corrected peer work
```
✏️ UPDATED: mingkim (ID: 190800)
   ⭐ CP: 5 → 8
```
→ They earned 3 CP by peer reviewing 3 submissions

### 📍 Location Changes
**Meaning**: Student physically moved around campus
```
✏️ UPDATED: jchen (ID: 236282)
   📍 Location: c1r5s2 → c2r1s3
```
→ They moved from desk c1r5s2 to desk c2r1s3 (working on different project)

```
✏️ UPDATED: lramos (ID: 158965)
   📍 Location: c1r9s4 → (empty)
```
→ They logged off/left campus

### 🟢 Active Status Changes
**Meaning**: Student enrollment changed
```
✏️ UPDATED: amiller (ID: 240043)
   🟢 Active: True → False
```
→ Student graduated, dropped out, or suspended

### 🆕 New User
**Meaning**: User just joined the 42 network at this campus
```
🆕 NEW USER: tsato (ID: 248840)
   💰 Wallet: 0 | ⭐ CP: 5
   📍 Location: c2r12s5 | 🟢 Active: True
```
→ Brand new student just started, assigned a desk, ready to go

---

## Typical Patterns You'll See

### Active Learning Session
```
🆕 NEW USER: student (ID: 200001)
   💰 Wallet: 0 | ⭐ CP: 0
   📍 Location: c1r1s1
```
→ Then shortly after:
```
✏️ UPDATED: student (ID: 200001)
   📍 Location: c1r1s1 → c1r2s1  (moved to code review station)
   
✏️ UPDATED: student (ID: 200001)
   ⭐ CP: 0 → 3  (reviewed 3 peers)
```

### Project Completion Pattern
```
✏️ UPDATED: student (ID: 200002)
   💰 Wallet: 10 → 15  (completed a project)
   ⭐ CP: 2 → 5         (submitted peer reviews)
   📍 Location: c3r5s2  (at submission desk)
```

### End of Day / Leaving Campus
```
✏️ UPDATED: student (ID: 200003)
   📍 Location: c1r10s5 → (empty)
```
→ Logged off, left campus

---

## Database Sync Process

### Each 30-second cycle:
1. **Fetch** from 42 API: "Who changed in last 30s?"
2. **Filter** to `kind=student` only (ignore staff, alumni)
3. **Compare** with current DB state
4. **Show deltas**: What actually changed
5. **Update** DB with new values

### What Happens Behind the Scenes

```
API Response: student has wallet=25, location=c2r5s1
              
DB Current:   student has wallet=20, location=c2r5s1

DELTA:        💰 Wallet: 20 → 25 ✏️ UPDATED
```

---

## False Positives You Might See

### "Server-side update only"
```
✏️ UPDATED: student
   📍 Location: (empty) → (empty)
```
→ Location didn't change, just API notification
→ Usually filtered out by better comparison logic

### New users every 30s
```
🆕 NEW USER: many_students
```
→ School is actively onboarding new cohorts
→ Normal during enrollment periods (July, January, Sept)

---

## Using the Data

### For Campus Management
- **Location tracking** → Optimize seating, study space allocation
- **Activity levels** → Peak hours, quiet hours

### For Student Support
- **Wallet patterns** → Identify struggling students (wallet stuck at 0)
- **CP patterns** → Find peer mentors (high CP)
- **Presence** → Check if students are utilizing campus

### For Analytics
- **Cohort progress** → Track pool_month groups through curriculum
- **Completion rates** → Watch for alumni transition
- **Engagement** → Wallet + CP growth over time

---

## Commands to Monitor

```bash
# Watch live changes in real-time
bash scripts/test/live_delta_monitor.sh 30

# See all API activity (even unchanged users)
bash scripts/test/live_events_realtime_poc.sh 30

# Check database sync status
tail -f logs/live_sync_loop.log

# See all students in database
docker compose exec -T db psql -U api42 -d api42 \
  -c "SELECT login, wallet, correction_point, location, active 
       FROM users WHERE kind='student' AND active=true 
       ORDER BY updated_at DESC LIMIT 20;"
```

---

## Database Health Checks

### How fresh is the data?
```sql
SELECT 
  MAX(updated_at) as "Latest API update",
  MAX(ingested_at) as "Latest DB sync",
  (NOW() - MAX(ingested_at)) as "Sync age"
FROM users;
```

### Any students we're missing?
```sql
SELECT COUNT(*) FROM users WHERE kind='student' AND active=true;
```

### Who's most engaged?
```sql
SELECT login, wallet, correction_point 
FROM users 
WHERE kind='student' AND active=true
ORDER BY (wallet + correction_point) DESC LIMIT 10;
```
