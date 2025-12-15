#!/usr/bin/env bash
# Aliases for 42_Network project management

# Backlog worker aliases
alias work.start='bash /srv/42_Network/repo/scripts/backlog_worker_manager.sh start'
alias work.stop='bash /srv/42_Network/repo/scripts/backlog_worker_manager.sh stop'
alias work.status='bash /srv/42_Network/repo/scripts/backlog_worker_manager.sh status'
alias work.restart='bash /srv/42_Network/repo/scripts/backlog_worker_manager.sh restart'

# Detector aliases
alias detect.start='bash /srv/42_Network/repo/scripts/detector_manager.sh start'
alias detect.stop='bash /srv/42_Network/repo/scripts/detector_manager.sh stop'
alias detect.status='bash /srv/42_Network/repo/scripts/detector_manager.sh status'
alias detect.restart='bash /srv/42_Network/repo/scripts/detector_manager.sh restart'

# Logs shortcuts
alias log.work='tail -f /srv/42_Network/repo/logs/backlog_worker.log'
alias log.detect='tail -f /srv/42_Network/repo/logs/detect_changes.log'
