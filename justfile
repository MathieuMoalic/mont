default:
    @just --list

backend:
    cd backend && cargo watch -q -c -w src -w Cargo.toml -x 'run -- -v'

android:
  adb reverse tcp:8080 tcp:8080
  cd flutter && flutter run --flavor dev -d CPH2465

web:
  cd flutter && flutter run -d web-server --web-hostname 127.0.0.1 --web-port 5173

cp-db:
  rm -rf /tmp/mont 
  mkdir /tmp/mont
  scp homeserver:/var/lib/mont/mont.sqlite /tmp/mont/mont.sqlite

# Build release artifacts, update flake.nix hash, commit, and tag
release TYPE:
    python3 scripts/release.py release "{{TYPE}}"
    just update-server

update-server:
    ssh homeserver "cd /home/mat/nix; nix flake update mont; up"

# Agent-managed commands

[private]
agent-init:
    mkdir -p .agent/logs

agent-backend: agent-init
    #!/usr/bin/env bash
    set -euo pipefail

    session="dev-backend"
    log="$PWD/.agent/logs/backend.log"

    tmux kill-session -t "$session" 2>/dev/null || true
    : > "$log"

    tmux new-session -d -s "$session" -c "$PWD/backend" \
      "cargo watch -q -c -w src -w Cargo.toml -x 'run -- -v'"

    tmux pipe-pane -o -t "$session" "cat >> '$log'"

agent-android: agent-init
    #!/usr/bin/env bash
    set -euo pipefail

    session="dev-android"
    log="$PWD/.agent/logs/android.log"

    tmux kill-session -t "$session" 2>/dev/null || true
    : > "$log"

    tmux new-session -d -s "$session" -c "$PWD/flutter" \
      "adb reverse tcp:8080 tcp:8080 && flutter run --flavor dev -d CPH2465"

    tmux pipe-pane -o -t "$session" "cat >> '$log'"

agent-web: agent-init
    #!/usr/bin/env bash
    set -euo pipefail

    session="dev-web"
    log="$PWD/.agent/logs/web.log"

    tmux kill-session -t "$session" 2>/dev/null || true
    : > "$log"

    tmux new-session -d -s "$session" -c "$PWD/flutter" \
      "flutter run -d web-server --web-hostname 127.0.0.1 --web-port 5173"

    tmux pipe-pane -o -t "$session" "cat >> '$log'"

agent-stop name:
    tmux kill-session -t "dev-{{name}}" 2>/dev/null || true

agent-stop-all:
    tmux kill-session -t dev-backend 2>/dev/null || true
    tmux kill-session -t dev-android 2>/dev/null || true
    tmux kill-session -t dev-web 2>/dev/null || true

agent-restart name:
    just agent-stop {{name}}
    just agent-{{name}}

agent-logs name="backend":
    tail -n "${N:-200}" ".agent/logs/{{name}}.log"

agent-follow name="backend":
    tail -f ".agent/logs/{{name}}.log"

agent-attach name:
    tmux attach -t "dev-{{name}}"

agent-status:
    tmux list-sessions 2>/dev/null | grep '^dev-' || true

agent-send name key:
    tmux send-keys -t "dev-{{name}}" "{{key}}"
