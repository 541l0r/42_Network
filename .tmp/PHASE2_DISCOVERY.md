# Phase 2 Analysis - `active?` Field Discovery

## Summary
After extensive analysis of 40,335 Phase 2 users (cursus 21), the `active?` field **is NOT determined by `updated_at` timestamp alone**.

## Initial Hypotheses (REJECTED)
1. ✗ `active? = (days_since_update < 60)` → REJECTED (complete interleaving 186-936 days)
2. ✗ `active? = (wallet > threshold)` → REJECTED (random distribution 0-100k)  
3. ✗ `active? = (created_at age)` → REJECTED (overlapping distributions)

## Discovery: Pool Calendar Correlation 🎯

The field **strongly correlates with pool_year and pool_month**:

### 2025 Pool Distribution (Current Year)
- **July**: 91.0% active (1,371/1,506)
- **August**: 92.5% active (1,127/1,219)
- **September**: 93.2% active (865/928)
- **March**: 63.4% active (715/1,128)
- **November**: 32.8% active (45/137) ← Current month
- **February**: 56.4% active (447/793)

### 2024 Pool Distribution (Previous Year)
- **July**: 63.8% active (1,192/1,867)
- **August**: 58.1% active (975/1,677)
- **September**: 60.2% active (800/1,328)
- **March**: 48.0% active (429/893)
- **February**: 48.1% active (549/1,142)

### Older Pools (2023, 2022, etc.)
- Progressively lower active% rates (avg 30-50%)
- More recent cohorts = higher active rates

## Conclusion

**`active?` likely indicates whether a user is currently in or recently completed a piscine/bootcamp session.**

- High percentages (85-93%) during traditional bootcamp months (July-September)
- Lower during off-months (November: 32%)
- Could also include students currently attending or registered for upcoming sessions

## Implications for Sync Strategy

1. ❌ **Can't use as a reliable daily filter** - it's based on calendar/enrollment, not activity
2. ✅ **`updated_at` is still useful** - tracks real activity within a session
3. 📊 **Pool participation is the primary classifier**, not session presence
4. 💾 **Archiving strategy**: Combine `active?=false + pool_year < 2025` for cold storage

## Data Files Generated
- `.tmp/phase2_delta_analysis/` - Detailed field comparison (v1 vs v2)
- `.tmp/phase2_users_v1/all.json` - 40,341 users
- `.tmp/phase2_users_v2/all.json` - 40,335 users

## Next Steps
- Load v2 data to database
- Implement daily sync on `updated_at` (not `active?`)
- Weekly full sync as sanity check
- Document pool calendar correlation in Phase 3
