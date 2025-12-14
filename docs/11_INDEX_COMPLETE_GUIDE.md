# 📚 Documentation Index (Consolidated)

**Last Updated:** December 13, 2025  
**Status:** Consolidated from 30 to 14 active documents (53% reduction)  
**Archive:** 16 redundant files moved to `_archive/` folder

---

## 🚀 START HERE

1. **[_DOCS_START_HERE.md](../_DOCS_START_HERE.md)** - Quick navigation (in root)
2. **[00_CONFIGURATION_CONSOLIDATED.md](00_CONFIGURATION_CONSOLIDATED.md)** - All config + parameters
3. **[QUICK_START.md](QUICK_START.md)** - Deploy in 5 minutes
4. **[CLAUDE_CONTEXT_MEMORY.md](CLAUDE_CONTEXT_MEMORY.md)** - Project state (for AI)

---

## 📖 ACTIVE DOCUMENTATION (Canonical Sources)

### Core Architecture & Pipeline
- **[CURSUS_21_DATA_PIPELINE.md](CURSUS_21_DATA_PIPELINE.md)** - Data flow: API → fetch → load
- **[PIPELINE_VISUAL_GUIDE.md](PIPELINE_VISUAL_GUIDE.md)** - Visual diagrams of data flow
- **[PRE_PHASE_END_ANALYSIS.md](PRE_PHASE_END_ANALYSIS.md)** - Database state & analysis

### Configuration (Consolidated)
- **[00_CONFIGURATION_CONSOLIDATED.md](00_CONFIGURATION_CONSOLIDATED.md)** ← USE THIS
  - Replaces: CONFIG_PARAMETERS.md + PARAMETERS_QUICK_REFERENCE.md
  - Also covers: Database schema, deployment, constraints

### Backlog System (Consolidated)
- **[01_BACKLOG_CONSOLIDATED.md](01_BACKLOG_CONSOLIDATED.md)** ← USE THIS
  - Replaces: BACKLOG_SYSTEM.md + BACKLOG_README.md + MIGRATION_ROLLING_TO_BACKLOG.md
  - Covers: Queue management, error handling, migration details

### Monitoring (Consolidated)
- **[02_MONITORING_CONSOLIDATED.md](02_MONITORING_CONSOLIDATED.md)** ← USE THIS
  - Replaces: MONITORING_SYSTEM.md + PHASE2_MONITORING_SYSTEM.md + LIVE_MONITORING_GUIDE.md + COALITION_FETCHING_LOGS.md
  - Covers: Real-time monitoring, logs, metrics, recovery procedures

### Reference & Commands
- **[COMMAND_REFERENCE.md](COMMAND_REFERENCE.md)** - All CLI commands
- **[README.md](README.md)** - Project overview

---

## 🗂️ ARCHIVED / DEPRECATED DOCUMENTS

These files are kept for **historical reference only**. Use consolidated versions above.

| Deprecated | Replaced By | Reason |
|-----------|------------|--------|
| CONFIG_PARAMETERS.md | 00_CONFIGURATION_CONSOLIDATED.md | Redundant duplicate |
| PARAMETERS_QUICK_REFERENCE.md | 00_CONFIGURATION_CONSOLIDATED.md | Merged into config |
| BACKLOG_SYSTEM.md | 01_BACKLOG_CONSOLIDATED.md | Consolidated 3 docs |
| BACKLOG_README.md | 01_BACKLOG_CONSOLIDATED.md | Consolidated 3 docs |
| MIGRATION_ROLLING_TO_BACKLOG.md | 01_BACKLOG_CONSOLIDATED.md | Consolidated 3 docs |
| MONITORING_SYSTEM.md | 02_MONITORING_CONSOLIDATED.md | Consolidated 4 docs |
| PHASE2_MONITORING_SYSTEM.md | 02_MONITORING_CONSOLIDATED.md | Consolidated 4 docs |
| LIVE_MONITORING_GUIDE.md | 02_MONITORING_CONSOLIDATED.md | Consolidated 4 docs |
| COALITION_FETCHING_LOGS.md | 02_MONITORING_CONSOLIDATED.md | Consolidated 4 docs |
| IMPLEMENTATION_SUMMARY.md | 00_CONFIGURATION_CONSOLIDATED.md | Phase info moved |
| IMPLEMENTATION_CHECKLIST.md | 00_CONFIGURATION_CONSOLIDATED.md | Phase info moved |
| COALITION_TABLES_SCHEMA.md | CURSUS_21_DATA_PIPELINE.md | Schema in pipeline doc |
| ALUMNI_FILTER_GUARANTEE.md | CURSUS_21_DATA_PIPELINE.md | Filter logic in pipeline |
| API_OPTIMIZATION_STRATEGY.md | 00_CONFIGURATION_CONSOLIDATED.md | Load profile moved |
| README_CURSUS21.md | README.md | Merged into main README |
| TODO_users_pipeline.md | CLAUDE_CONTEXT_MEMORY.md | Tracked in context |

---

## 🔍 How to Find What You Need

### "How do I deploy?"
→ **QUICK_START.md** (5 min overview) or **CURSUS_21_DATA_PIPELINE.md** (detailed)

### "What are the configuration options?"
→ **00_CONFIGURATION_CONSOLIDATED.md** (everything in one place)

### "How does backlog polling work?"
→ **01_BACKLOG_CONSOLIDATED.md** (architecture + config + migration)

### "How do I monitor the system?"
→ **02_MONITORING_CONSOLIDATED.md** (logs + metrics + alerts)

### "What's the database schema?"
→ **CURSUS_21_DATA_PIPELINE.md** (schema + relationships)

### "What was the original project plan?"
→ **CLAUDE_CONTEXT_MEMORY.md** (decision log + history)

---

## ✨ For AI Continuity

**When resuming this project, read in this order**:
1. `CLAUDE_CONTEXT_MEMORY.md` - Full project state
2. `00_CONFIGURATION_CONSOLIDATED.md` - All settings
3. `01_BACKLOG_CONSOLIDATED.md` - Queue system
4. `02_MONITORING_CONSOLIDATED.md` - Observability
5. `CURSUS_21_DATA_PIPELINE.md` - Architecture details

---

*Last consolidated: December 13, 2025*
