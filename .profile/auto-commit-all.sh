#!/bin/bash

# --- Configuration ---
# The base folder to search for Git repositories
BASE_DIR="/workspaces"

# The check interval (in seconds)
SLEEP_INTERVAL=10
# ---------------------

# --- Script Logic ---

# Check if an argument (a target directory) was provided
if [ $# -eq 0 ]; then
    ### LAUNCHER MODE ###
    # No arguments given: Find all repos and launch watchers.
    
    echo "Launcher Mode: Finding all git repos under $BASE_DIR..."
    
    # Get the full, absolute path to this script
    # This is crucial for nohup to find it
    SCRIPT_PATH=$(realpath "$0")
    
    # Check if realpath is installed (common, but good to check)
    if [ ! -f "$SCRIPT_PATH" ]; then
        echo "Error: Could not determine script's full path. Is 'realpath' installed?"
        exit 1
    fi
    
    # Find every directory named ".git"
    # Then get its parent directory (the repo root)
    find "$BASE_DIR" -type d -name ".git" | while read GIT_DIR; do
        REPO_DIR=$(dirname "$GIT_DIR")
        echo " - Found repo: $REPO_DIR"
        
        # Sanitize the repo path to create a unique log file name
        # Replaces '/' with '_' and removes leading '_'
        LOG_NAME=$(echo "$REPO_DIR" | tr '/' '_' | sed 's/^_//')
        LOG_FILE="/tmp/auto-commit-$LOG_NAME.log"
        
        echo "   -> Attempting to start watcher. Log file: $LOG_FILE"
        
        # Launch the watcher in the background
        # It calls THIS SCRIPT again, but with $REPO_DIR as an argument
        # The 'flock' in the watcher will prevent duplicates
        nohup bash "$SCRIPT_PATH" "$REPO_DIR" > "$LOG_FILE" 2>&1 &
        
    done
    
    echo "Launcher finished. Watcher processes are starting."
    echo "You can check /tmp/auto-commit-*.log files for status."
    
else
    ### WATCHER MODE ###
    # Argument provided: This is the watcher for a single repo.
    
    TARGET_DIR="$1"
    
    # --- Unique Lock File ---
    # Create a unique lock file name based on the repo path
    LOCK_NAME=$(echo "$TARGET_DIR" | tr -c 'a-zA-Z0-9' '_')
    LOCKFILE="/tmp/auto-commit-lock-$LOCK_NAME.lock"

    # Open file descriptor 200 for the lock
    exec 200>"$LOCKFILE"
    
    # Try to acquire a non-blocking lock. If it fails, exit.
    flock -n 200 || {
        echo "[$TARGET_DIR] Error: Watcher is already running. Exiting."
        exec 200>&- # Close FD
        exit 1
    }
    
    # --- Main Watcher Loop ---
    echo "[$TARGET_DIR] Watcher started (PID: $$). Lock acquired."
    
    # Go to the target directory
    cd "$TARGET_DIR" || { 
        echo "[$TARGET_DIR] Error: Could not navigate to $TARGET_DIR. Exiting."
        exec 200>&- # Release lock
        exit 1 
    }
    
    # Graceful exit on Ctrl+C or kill
    trap 'echo "[$TARGET_DIR] Exiting and releasing lock."; exec 200>&-; exit 0' SIGINT SIGTERM

    while true
    do
        # Check for changes
        if [ -n "$(git status --porcelain)" ]; then
            echo "[$TARGET_DIR] Changes detected at $(date +'%Y-%m-%d %H:%M:%S'). Committing..."
            
            git add .
            git commit -m "auto-commit: $(date +'%Y-%m-%d %H:%M:%S')"
            
            echo "[$TARGET_DIR] Commit complete. Waiting..."
        fi
        
        sleep $SLEEP_INTERVAL
    done
fi
