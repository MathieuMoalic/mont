# Bump version (major, minor, or patch)
bump TYPE:
    #!/usr/bin/env bash
    set -euo pipefail

    current=$(grep '^version = ' backend/Cargo.toml | head -1 | sed 's/version = "\(.*\)"/\1/')
    IFS='.' read -r major minor patch <<< "$current"

    case "{{TYPE}}" in
        major) major=$((major + 1)); minor=0; patch=0 ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        patch) patch=$((patch + 1)) ;;
        *) echo "Error: TYPE must be major, minor, or patch"; exit 1 ;;
    esac

    new_version="$major.$minor.$patch"
    echo "Bumping version: $current → $new_version"

    sed -i "s/^version = \"$current\"/version = \"$new_version\"/" backend/Cargo.toml
    sed -i "s/^version: $current$/version: $new_version/" flutter/pubspec.yaml
    (cd backend && cargo check --quiet)

    git add backend/Cargo.toml backend/Cargo.lock flutter/pubspec.yaml
    git diff --cached
    git commit -m "Bump version to $new_version"
    git tag -a "v$new_version" -m "Release v$new_version"
    echo "✓ Version bumped to $new_version and tagged"

backend:
    cd backend && cargo watch -q -c -w src -w Cargo.toml -x 'run -- -v'

android:
  adb reverse tcp:8080 tcp:8080
  cd flutter && flutter run --flavor dev -d CPH2465

web:
  cd flutter && flutter run -d web-server --web-hostname 127.0.0.1 --web-port 5173
