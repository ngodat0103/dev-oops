#!/usr/bin/env bash
# lib/log.sh — minimal structured logging helpers.

# Colours only when stdout is a TTY (keeps CI logs clean).
if [ -t 1 ]; then
  _C_RESET=$'\033[0m'; _C_BLUE=$'\033[34m'; _C_GREEN=$'\033[32m'
  _C_YELLOW=$'\033[33m'; _C_RED=$'\033[31m'; _C_DIM=$'\033[2m'
else
  _C_RESET=''; _C_BLUE=''; _C_GREEN=''; _C_YELLOW=''; _C_RED=''; _C_DIM=''
fi

_ts() { date -u +'%H:%M:%S'; }

log_info()  { printf '%s%s%s %s\n'  "$_C_DIM" "$(_ts)" "$_C_RESET" "$*"; }
log_step()  { printf '\n%s==> %s%s\n' "$_C_BLUE" "$*" "$_C_RESET"; }
log_ok()    { printf '%s[OK]%s %s\n'   "$_C_GREEN" "$_C_RESET" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; }

# die <message> — log and exit non-zero.
die() { log_error "$*"; exit 1; }