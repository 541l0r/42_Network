# Phase 3 PoC - Globe Visualization Setup

## Quick Start

### 1. Install dependencies
```bash
cd /srv/42_Network/repo/api
npm install
```

### 2. Run the API server (with WebSocket support)
```bash
cd /srv/42_Network/repo
PORT=3000 node api/server.js
```

### 3. Open the globe visualization
```
http://localhost:3000/globe.html
```

### 4. Start the pipeline (if not already running)
```bash
bash scripts/pipeline_manager.sh restart
```

## What You'll See

### Globe
- **Blue rotating sphere** = 42 network
- **Green dots** = Campus locations (animated pulse)
- **Yellow pulse** = Active update happening

### Real-time Feed
Shows each user as it's synced:
- **User ID & Login** 
- **Campus location**
- **Wallet & Points**
- **🔴 SUSPICIOUS FLAG** = No location data found

## Track Changes

The system logs:
- ✅ **Connected users** - location available
- 🔴 **Suspicious users** - NO location data (you'll see these highlighted in red in the feed)
- 💰 **Wallet updates** - shown with each sync
- 📍 **Campus distribution** - visualized on globe

## Architecture

```
Upserter (every user)
    ↓
curl POST /api/user-updated
    ↓
API Server (server.js)
    ↓
WebSocket broadcast to all clients
    ↓
glob.html receives and visualizes
    ↓
Logs suspicious data (no location, etc.)
```

## API Endpoints

- `GET /api/stats` - Total users & campuses
- `POST /api/user-updated` - Receive updates (called by upserter)
- `GET /globe.html` - Visualization page
- `WS ws://localhost:3000` - WebSocket for real-time updates

## Suspicious Data Investigation

Watch the feed for:
- **Red flag: 📍 NO LOCATION** - User has no location field in API response
- The feed shows `[SUSPICIOUS]` entries with user ID

This helps identify:
1. Users with incomplete profiles
2. Connection/sync issues
3. Data quality problems in 42 API

## Next Steps After Monday

1. **Add campus coordinates** - Real lat/long for globe rotation
2. **Filter by time window** - Show only recent updates
3. **Zoom & details** - Click campus to see detailed stats
4. **Historical tracking** - Graph of changes over time
5. **Alert thresholds** - Notify on anomalies
