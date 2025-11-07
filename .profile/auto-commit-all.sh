#!/bin/bash

# --- Configuration ---
# The base folder to search for Git repositories
BASE_DIR="/workspaces"

# The check interval (in seconds)
SLEEP_INTERVAL=10

# The name of the primary branch to sync
MAIN_BRANCH="main"
# ---------------------

# --- Script Logic ---

if [ $# -eq 0 ]; then
    ### LAUNCHER MODE ###
    echo "Launcher Mode: Finding all git repos under $BASE_DIR..."
    
    SCRIPT_PATH=$(realpath "$0")
    
    if [ ! -f "$SCRIPT_PATH" ]; then
        echo "Error: Could not determine script's full path. Is 'realpath' installed?"
        exit 1
    fi
    
    find "$BASE_DIR" -type d -name ".git" | while read GIT_DIR; do
        REPO_DIR=$(dirname "$GIT_DIR")
        echo " - Found repo: $REPO_DIR"
        
        LOG_NAME=$(echo "$REPO_DIR" | tr '/' '_' | sed 's/^_//')
        LOG_FILE="/tmp/auto-commit-$LOG_NAME.log"
        
        echo "   -> Attempting to start watcher. Log file: $LOG_FILE"
        
        # Call bash to run the script, no executable permission needed
        nohup bash "$SCRIPT_PATH" "$REPO_DIR" > "$LOG_FILE" 2>&1 &
        
    done
    
    echo "Launcher finished. Watcher processes are starting."
    echo "You can check /tmp/auto-commit-*.log files for status."
    
else
    ### WATCHER MODE ###
    TARGET_DIR="$1"
    
    LOCK_NAME=$(echo "$TARGET_DIR" | tr -c 'a-zA-Z0-9' '_')
    LOCKFILE="/tmp/auto-commit-lock-$LOCK_NAME.lock"

    # Open file descriptor 200 for the lock
    exec 200>"$LOCKFILE"
    
    # Try to acquire a non-blocking lock. If it fails, exit.
    flock -n 200 || {
        echo "[$TARGET_DIR] Error: Watcher is already running. Exiting."
        exec 200>&- 
        exit 1
    }
    
    # Set trap for graceful exit *after* lock is acquired
    trap 'echo "[$TARGET_DIR] Exiting and releasing lock."; exec 200>&-; exit 0' SIGINT SIGTERM
    
    echo "[$TARGET_DIR] Watcher starting (PID: $$). Lock acquired."
    
    cd "$TARGET_DIR" || { 
        echo "[$TARGET_DIR] Error: Could not navigate to $TARGET_DIR. Exiting."
        exec 200>&- 
        exit 1 
    }

    # --- NEW: Save local changes and sync with origin ---
    echo "[$TARGET_DIR] Checking for local changes before sync..."
    
    # 1. Save any uncommitted changes to a new branch
    if [ -n "$(git status --porcelain)" ]; then
        BRANCH_NAME="codespace-backup-$(date +'%Y%m%d-%H%M%S')"
        echo "[$TARGET_DIR]   -> Uncommitted changes found. Saving to new branch: $BRANCH_NAME"
        
        git checkout -b "$BRANCH_NAME" || { echo "[$TARGET_DIR] Error: Failed to create backup branch. Exiting."; exec 200>&-; exit 1; }
        git add .
        git commit -m "Auto-backup of local changes" || { echo "[$TARGET_DIR] Error: Failed to commit to backup branch. Exiting."; exec 200>&-; exit 1; }
        
        echo "[$TARGET_DIR]   -> Backup complete."
    else
        echo "[$TARGET_DIR]   -> No uncommitted changes found. Skipping backup."
    fi
    
    # 2. Fetch origin and force-reset the main branch
    echo "[$TARGET_DIR] Fetching latest changes from origin..."
    git fetch origin || { echo "[$TARGET_DIR] Error: 'git fetch origin' failed. Check network/remote. Exiting."; exec 200>&-; exit 1; }
    
    echo "[$TARGET_DIR] Switching to $MAIN_BRANCH and resetting to origin/$MAIN_BRANCH..."
    git checkout "$MAIN_BRANCH" || { echo "[$TARGET_DIR] Error: Could not check out $MAIN_BRANCH. Exiting."; exec 200>&-; exit 1; }
    
    git reset --hard "origin/$MAIN_BRANCH" || { echo "[$TARGET_DIR] Error: Could not reset to origin/$MAIN_BRANCH. Exiting."; exec 200>&-; exit 1; }
    
    echo "[$TARGET_DIR] Sync complete. Now watching $MAIN_BRANCH for changes."
    # --- End of new logic ---

    # Start the main watcher loop
    while true
    do
        if [ -n "$(git status --porcelain)" ]; then
            echo "[$TARGET_DIR] Changes detected at $(date +'%Y-%m-%d %H:%M:%S'). Committing..."
            
            git add .
            git commit -m "auto-commit: $(date +'%Y-%m-%d %H:%M:%S')"
            
            echo "[$TARGET_DIR] Commit complete. Waiting..."
        fi
        
        sleep $SLEEP_INTERVAL
    done
fi
