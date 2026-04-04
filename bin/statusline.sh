#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

echo "$input" | jq . > ~/.claude/statusline-input.json 2>/dev/null

# ── Colors ──────────────────────────────────────────────
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;175;80m'
cyan='\033[38;2;86;182;194m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
magenta='\033[38;2;180;140;255m'
dim='\033[2m'
reset='\033[0m'

sep="  "

# ── Helpers ─────────────────────────────────────────────
format_tokens() {
    local num=$1
    if [ "$num" -ge 1000000 ]; then
        awk "BEGIN {printf \"%.1fm\", $num / 1000000}"
    elif [ "$num" -ge 1000 ]; then
        awk "BEGIN {printf \"%.0fk\", $num / 1000}"
    else
        printf "%d" "$num"
    fi
}

color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$orange"
    elif [ "$pct" -ge 50 ]; then printf "$yellow"
    else printf "$green"
    fi
}

color_for_context_pct() {
    local pct=$1
    if [ "$pct" -ge 25 ]; then printf "$red"
    elif [ "$pct" -ge 20 ]; then printf "$orange"
    elif [ "$pct" -ge 15 ]; then printf "$yellow"
    else printf "$green"
    fi
}

color_for_weekly_pace() {
    local pct=$1
    if [ "$pct" -ge 100 ]; then printf "$red"
    elif [ "$pct" -ge 90 ]; then printf "$orange"
    elif [ "$pct" -ge 80 ]; then printf "$yellow"
    else printf "$green"
    fi
}

build_bar() {
    local pct=$1
    local width=$2
    local color_pct=${3:-$pct}
    local color_fn=${4:-color_for_pct}
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar_color
    bar_color=$($color_fn "$color_pct")

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

iso_to_epoch() {
    local iso_str="$1"

    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

# ── Extract JSON data ───────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')

size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))

used_tokens=$(format_tokens $current)
total_tokens=$(format_tokens $size)

if [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
else
    pct_used=0
fi

effort="default"
settings_path="$HOME/.claude/settings.json"
if [ -f "$settings_path" ]; then
    effort=$(jq -r '.effortLevel // "default"' "$settings_path" 2>/dev/null)
fi

# ── LINE 1: Model │ Context % │ Directory (branch) │ Session │ Thinking ──
pct_color=$(color_for_context_pct "$pct_used")
cwd=$(echo "$input" | jq -r '.cwd // ""')
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)

# Use worktree path/branch when running inside a git worktree session
worktree_path=$(echo "$input" | jq -r '.worktree.path // empty')
if [ -n "$worktree_path" ] && [ -d "$worktree_path" ]; then
    git_dir="$worktree_path"
else
    git_dir="$cwd"
fi
dirname=$(basename "$git_dir")

git_branch=""
git_dirty=""
if git -C "$git_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$git_dir" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$(git -C "$git_dir" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
        git_dirty="*"
    fi
fi

session_duration=""
total_duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')
if [ -n "$total_duration_ms" ] && [ "$total_duration_ms" != "null" ]; then
    elapsed=$(( total_duration_ms / 1000 ))
    if [ "$elapsed" -ge 3600 ]; then
        session_duration="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
    elif [ "$elapsed" -ge 60 ]; then
        session_duration="$(( elapsed / 60 ))m"
    else
        session_duration="${elapsed}s"
    fi
fi

skip_perms=""
parent_cmd=$(ps -o args= -p "$PPID" 2>/dev/null)
if [[ "$parent_cmd" == *"--dangerously-skip-permissions"* ]]; then
    skip_perms="⚡  "
fi

line1="${skip_perms}${blue}${model_name}${reset}"
line1+="${sep}"
line1+="✍️ ${pct_color}${pct_used}%${reset}"
if [ -n "$session_duration" ]; then
    line1+="${sep}"
    line1+="${dim}⏱ ${reset}${white}${session_duration}${reset}"
fi
line1+="${sep}"
case "$effort" in
    high)   line1+="${magenta}● ${effort}${reset}" ;;
    medium) line1+="${dim}◑ ${effort}${reset}" ;;
    low)    line1+="${dim}◔ ${effort}${reset}" ;;
    *)      line1+="${dim}◑ ${effort}${reset}" ;;
esac

# Peak hours indicator (weekdays 8AM-2PM EDT)
edt_hour=$(TZ="America/New_York" date +%-H)
edt_dow=$(TZ="America/New_York" date +%u)   # 1=Mon … 7=Sun
if [ "$edt_dow" -le 5 ] && [ "$edt_hour" -ge 8 ] && [ "$edt_hour" -lt 14 ]; then
    line1+=" ${red}peak${reset}"
fi

total_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
cost_int=${total_cost%.*}
if [ "${cost_int:-0}" -gt 0 ] 2>/dev/null; then
    line1+="${sep}${green}\$${cost_int}${reset}"
fi

# ── Rate limit data from CC input ──────────────────────
format_reset_epoch() {
    local epoch=$1
    [ -z "$epoch" ] || [ "$epoch" = "null" ] && return

    local now_epoch
    now_epoch=$(date +%s)
    local remaining=$(( epoch - now_epoch ))
    if [ "$remaining" -lt 0 ]; then remaining=0; fi

    if [ "$remaining" -ge 172800 ]; then
        printf "%3s" "$(( remaining / 86400 ))d"
    elif [ "$remaining" -ge 7200 ]; then
        printf "%3s" "$(( remaining / 3600 ))h"
    elif [ "$remaining" -ge 60 ]; then
        printf "%3s" "$(( remaining / 60 ))m"
    else
        printf "%3s" "<1m"
    fi
}

# ── Rate limit lines ────────────────────────────────────
rate_lines=""

five_hour_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' | awk '{printf "%.0f", $1}')
seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' | awk '{printf "%.0f", $1}')

if [ -n "$five_hour_pct" ] || [ -n "$seven_day_pct" ]; then
    bar_width=10

    five_hour_pct=${five_hour_pct:-0}
    five_hour_reset_epoch=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
    five_hour_reset=$(format_reset_epoch "$five_hour_reset_epoch")
    five_hour_bar=$(build_bar "$five_hour_pct" "$bar_width")
    five_hour_pct_color=$(color_for_pct "$five_hour_pct")
    five_hour_pct_fmt=$(printf "%3d" "$five_hour_pct")

    # 5-hour pace projection (always shown, fixed 3-char width)
    fh_pace_pct="$five_hour_pct"
    if [ "$five_hour_pct" -ge 5 ] 2>/dev/null && [ -n "$five_hour_reset_epoch" ] && [ "$five_hour_reset_epoch" != "null" ]; then
        now_epoch=$(date +%s)
        fh_window_start=$(( five_hour_reset_epoch - 5 * 3600 ))
        fh_elapsed_min=$(( (now_epoch - fh_window_start) / 60 ))
        if [ "$fh_elapsed_min" -gt 0 ] && [ "$fh_elapsed_min" -le 300 ]; then
            fh_time_pct=$(( fh_elapsed_min * 100 / 300 ))
            if [ "$fh_time_pct" -gt 0 ]; then
                fh_pace_pct=$(( five_hour_pct * 100 / fh_time_pct ))
                [ "$fh_pace_pct" -gt 200 ] && fh_pace_pct=200
            fi
        fi
    fi
    fh_proj_color=$(color_for_weekly_pace "$fh_pace_pct")
    fh_pace_fmt=$(printf "%3d" "$fh_pace_pct")
    five_hour_projected=" ${dim}→${reset}${fh_proj_color}${fh_pace_fmt}%${reset}"

    rate_lines+="${white}current${reset} ${five_hour_bar} ${five_hour_pct_color}${five_hour_pct_fmt}%${reset}${five_hour_projected} ${dim}⟳${reset} ${white}${five_hour_reset}${reset}${sep}${dim}f:${reset} ${cyan}${dirname}${reset}"

    seven_day_pct=${seven_day_pct:-0}
    seven_day_reset_epoch=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
    seven_day_reset=$(format_reset_epoch "$seven_day_reset_epoch")

    # Pace-aware coloring: project end-of-window usage from current pace
    seven_day_pace_pct="$seven_day_pct"
    if [ "$seven_day_pct" -lt 20 ] 2>/dev/null; then
        # Too early / too little usage for meaningful projection — force green
        seven_day_pace_pct=0
    elif [ -n "$seven_day_reset_epoch" ] && [ "$seven_day_reset_epoch" != "null" ]; then
        now_epoch=$(date +%s)
        window_start=$(( seven_day_reset_epoch - 7 * 86400 ))
        elapsed_hrs=$(( (now_epoch - window_start) / 3600 ))
        total_hrs=168
        if [ "$elapsed_hrs" -gt 0 ] && [ "$elapsed_hrs" -le "$total_hrs" ]; then
            time_pct=$(( elapsed_hrs * 100 / total_hrs ))
            if [ "$time_pct" -gt 0 ]; then
                seven_day_pace_pct=$(( seven_day_pct * 100 / time_pct ))
                [ "$seven_day_pace_pct" -gt 200 ] && seven_day_pace_pct=200
            fi
        fi
    fi

    seven_day_bar=$(build_bar "$seven_day_pct" "$bar_width" "$seven_day_pace_pct" color_for_weekly_pace)
    seven_day_pct_color=$(color_for_weekly_pace "$seven_day_pace_pct")
    seven_day_pct_fmt=$(printf "%3d" "$seven_day_pct")

    # Weekly pace projection (always shown, fixed 3-char width)
    if [ "$seven_day_pace_pct" -le 0 ] 2>/dev/null; then
        seven_day_pace_pct="$seven_day_pct"
    fi
    sd_proj_color=$(color_for_weekly_pace "$seven_day_pace_pct")
    sd_pace_fmt=$(printf "%3d" "$seven_day_pace_pct")
    seven_day_projected=" ${dim}→${reset}${sd_proj_color}${sd_pace_fmt}%${reset}"

    branch_info=""
    if [ -n "$git_branch" ]; then
        branch_info="${sep}${dim}b:${reset} ${green}${git_branch}${red}${git_dirty}${reset}"
    fi
    rate_lines+="\n${white}weekly${reset}  ${seven_day_bar} ${seven_day_pct_color}${seven_day_pct_fmt}%${reset}${seven_day_projected} ${dim}⟳${reset} ${white}${seven_day_reset}${reset}${branch_info}"
fi

# ── Output ──────────────────────────────────────────────
printf "%b" "$line1"
[ -n "$rate_lines" ] && printf "\n\n%b" "$rate_lines"

exit 0
