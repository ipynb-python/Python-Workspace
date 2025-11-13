#!/bin/bash

# --- Configuration ---
BASE_DIR="/workspaces"
SLEEP_INTERVAL=10
SHADOW_BASE_DIR="/tmp/autosave-shadows"

# --- NEW: Set the main branch and autosave branch names ---
MAIN_BRANCH_NAME="main"
AUTOSAVE_BRANCH_NAME="autosave"
# ---------------------

# --- Script Logic ---

# --- Halt Flag Check ---
if [ "$1" == "-h" ]; then
    echo "Halt flag detected. Stopping all running watcher processes..."
    EXISTING_PIDS=$(pgrep -f "$0" | grep -v $$)
    
    if [ -n "$EXISTING_PIDS" ]; then
        for PID in $EXISTING_PIDS; do
            echo " - Stopping (PID: $PID)..."
            kill "$PID"
        done
        echo "All processes halted."
    else
        echo "No running processes found."
    fi
    exit 0
fi

if [ $# -eq 0 ]; then
    ### LAUNCHER MODE ###
    
    SCRIPT_PATH=$(realpath "$0")
    
    echo "Launcher Mode: Stopping all existing watcher processes..."
    EXISTING_PIDS=$(pgrep -f "$SCRIPT_PATH" | grep -v $$)
    
    if [ -n "$EXISTING_PIDS" ]; then
        for PID in $EXISTING_PIDS; do
            echo " - Stopping old watcher (PID: $PID)..."
            kill "$PID"
        done
        echo "Waiting for old processes to release locks..."
        sleep 1
    else
        echo "No existing watcher processes found."
    fi

    echo "Restart complete. Finding all git repos under $BASE_DIR..."
    
    if [ ! -f "$SCRIPT_PATH" ]; then
        echo "Error: Could not determine script's full path. Is 'realpath' installed?"
        exit 1
    fi
    
    find "$BASE_DIR" -type d -name ".git" | while read GIT_DIR; do
        REPO_DIR=$(dirname "$GIT_DIR")
        echo " - Found repo: $REPO_DIR"
        
        LOG_NAME=$(echo "$REPO_DIR" | tr '/' '_' | sed 's/^_//')
        LOG_FILE="/tmp/auto-commit-$LOG_NAME.log"
        
        echo "   -> Attempting to start new watcher. Log file: $LOG_FILE"
        bash nohup "$SCRIPT_PATH" "$REPO_DIR" > "$LOG_FILE" 2>&1 &
        
    done
    
    echo "Launcher finished. New watcher processes are starting."
    echo "Close this terminal to stop all watchers."
    
else
    ### WATCHER MODE ###
    TARGET_DIR="$1"
    
    # --- 1. Set up Lock ---
    LOCK_NAME=$(echo "$TARGET_DIR" | tr -c 'a-zA-Z0-9' '_')
    LOCKFILE="/tmp/auto-commit-lock-$LOCK_NAME.lock"

    exec 200>"$LOCKFILE"
    
    flock -n 200 || {
        echo "[$TARGET_DIR] Error: Watcher is already running. Exiting."
        exec 200>&- 
        exit 1
    }
    
    trap 'echo "[$TARGET_DIR] Watcher (PID: $$) stopping and releasing lock."; exec 200>&-; exit 0' SIGINT SIGTERM
    
    echo "[$TARGET_DIR] Watcher starting (PID: $$). Lock acquired."
    
    # --- NEW: Check if on Main Branch ---
    CURRENT_BRANCH=$(git -C "$TARGET_DIR" rev-parse --abbrev-ref HEAD)
    if [ "$CURRENT_BRANCH" != "$MAIN_BRANCH_NAME" ]; then
        echo "[$TARGET_DIR] Error: Watcher stopped. You are on branch '$CURRENT_BRANCH'."
        echo "[$TARGET_DIR] Autosave only works when you are on '$MAIN_BRANCH_NAME'."
        exec 200>&- # Release lock
        exit 1
    fi
    echo "[$TARGET_DIR] Verified you are on '$MAIN_BRANCH_NAME'. Proceeding."

    # --- 2. Set up Shadow Repo ---
    SHADOW_DIR="$SHADOW_BASE_DIR/$LOCK_NAME"
    mkdir -p "$SHADOW_BASE_DIR"
    
    echo "[$TARGET_DIR] Creating fresh shadow repo at: $SHADOW_DIR"
    rm -rf "$SHADOW_DIR"
    
    git clone "$TARGET_DIR" "$SHADOW_DIR" || { echo "[$TARGET_DIR] Error: Clone failed. Exiting."; exec 200>&-; exit 1; }
    cd "$SHADOW_DIR" || { echo "[$TARGET_DIR] Error: cd to shadow failed. Exiting."; exec 200>&-; exit 1; }
    
    # --- 3. Configure Remote and Branch ---
    echo "[$TARGET_DIR] Setting remote URL..."
    REAL_ORIGIN_URL=$(git -C "$TARGET_DIR" remote get-url origin)
    git remote set-url origin "$REAL_ORIGIN_URL"
    git config push.autoSetupRemote true
    
    echo "[$TARGET_DIR] Checking for existing branch $AUTOSAVE_BRANCH_NAME..."
    git fetch origin
    
    if git show-ref --verify --quiet "refs/remotes/origin/$AUTOSAVE_BRANCH_NAME"; then
        echo "[$TARGET_DIR]   -> Found remote branch. Resuming history."
        git checkout "$AUTOSAVE_BRANCH_NAME"
    else
        echo "[$TARGET_DIR]   -> No remote branch found. Creating new one."
        git checkout -b "$AUTOSAVE_BRANCH_NAME"
        
        # Add the warning file on the very first commit
        echo "WARNING: This is an automated branch. Do not work here. Your changes will be overwritten." > WARNING.txt
        git add WARNING.txt
        git commit -m "Init autosave and add WARNING.txt"
        git push origin "$AUTOSAVE_BRANCH_NAME"
    fi
    
    # --- 4. Main Watcher Loop ---
    echo "[$TARGET_DIR] Starting watch loop on $AUTOSAVE_BRANCH_NAME..."
    while true
    do
        # --- A. Sync with Remote ---
        # Fetch latest and reset our local branch to it.
        # This dumps any local commits that failed to push.
        # This is the "overwrite conflicts" part.
        git fetch origin
        git reset --hard "origin/$AUTOSAVE_BRANCH_NAME"
        
        # --- B. Copy Changes ---
        # rsync from main repo to shadow
        rsync -a --delete --exclude=".git" "$TARGET_DIR/" "$SHADOW_DIR/"
        
        # --- C. Ensure Warning File Exists ---
        # Re-add warning file in case rsync deleted it
        echo "WARNING: This is an automated branch. Do not work here. Your changes will be overwritten." > WARNING.txt
        
        # --- D. Commit and Push ---
        git add .
        
        if [ -n "$(git status --porcelain)" ]; then
            echo "[$TARGET_DIR] Changes detected at $(date +'%Ym%d-%H%M%S'). Committing..."
            
            git commit -m "auto-commit: $(date +'%Ym%d-%H%M%S')"
            
            echo "[$TARGET_DIR] Pushing to $AUTOSAVE_BRANCH_NAME..."
            
            # Standard (non-force) push.
            git push origin "$AUTOSAVE_BRANCH_NAME" || {
                echo "[$TARGET_DIR] WARNING: Push failed. Will be re-committed next cycle."
            }
            
            echo "[$TARGET_SESSION] Push complete. Waiting..."
        fi
        
        sleep $SLEEP_INTERVAL
    done
fi