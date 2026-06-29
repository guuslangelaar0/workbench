to_upper() { printf '%s\n' "$1" | tr '[:lower:]' '[:upper:]'; }
to_lower() { printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'; }
