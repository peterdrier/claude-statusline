#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

echo "$input" | jq . > ~/.claude/statusline-input.json 2>/dev/null

# ── Known payload schema (observed 2026-04-20, Claude Code v2.1.114) ────
# Diff `jq -r 'paths(scalars) | join(".")' ~/.claude/statusline-input.json`
# against this list to spot new/removed fields.
#
#   context_window.total_input_tokens
#   context_window.total_output_tokens
#   context_window.context_window_size
#   context_window.current_usage.input_tokens
#   context_window.current_usage.output_tokens
#   context_window.current_usage.cache_creation_input_tokens
#   context_window.current_usage.cache_read_input_tokens
#   context_window.used_percentage          [USED]
#   context_window.remaining_percentage
#   cost.total_cost_usd                     [USED]
#   cost.total_duration_ms                  [USED]
#   cost.total_api_duration_ms
#   cost.total_lines_added
#   cost.total_lines_removed
#   cwd                                     [USED — fallback]
#   exceeds_200k_tokens
#   model.id
#   model.display_name                      [USED]
#   output_style
#   rate_limits.five_hour.used_percentage   [USED]
#   rate_limits.five_hour.resets_at         [USED]
#   rate_limits.seven_day.used_percentage   [USED]
#   rate_limits.seven_day.resets_at         [USED]
#   session_id
#   transcript_path
#   version
#   workspace.current_dir                   [USED]
#   workspace.project_dir
#   workspace.added_dirs

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

# ── Extract JSON data ───────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')

pct_used=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | awk '{printf "%.0f", $1}')

effort="default"
settings_path="$HOME/.claude/settings.json"
if [ -f "$settings_path" ]; then
    effort=$(jq -r '.effortLevel // "default"' "$settings_path" 2>/dev/null)
fi

# ── LINE 1: Model │ Context % │ Directory (branch) │ Session │ Thinking ──
pct_color=$(color_for_context_pct "$pct_used")
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
[ -z "$cwd" ] && cwd=$(pwd)
git_dir="$cwd"
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

    # 5-hour pace projection (float internally, integer display, fixed 3-char width)
    fh_pace_pct="$five_hour_pct"
    if [ "$five_hour_pct" -ge 5 ] 2>/dev/null && [ -n "$five_hour_reset_epoch" ] && [ "$five_hour_reset_epoch" != "null" ]; then
        now_epoch=$(date +%s)
        fh_window_start=$(( five_hour_reset_epoch - 5 * 3600 ))
        fh_elapsed_min=$(( (now_epoch - fh_window_start) / 60 ))
        if [ "$fh_elapsed_min" -ge 3 ] && [ "$fh_elapsed_min" -le 300 ]; then
            fh_pace_pct=$(awk -v u="$five_hour_pct" -v e="$fh_elapsed_min" 'BEGIN { p = u * 300 / e; if (p > 200) p = 200; printf "%.1f", p }')
        fi
    fi
    fh_pace_int=${fh_pace_pct%.*}
    fh_proj_color=$(color_for_weekly_pace "$fh_pace_int")
    fh_pace_fmt=$(printf "%3s" "$fh_pace_int")
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
        if [ "$elapsed_hrs" -ge 2 ] && [ "$elapsed_hrs" -le "$total_hrs" ]; then
            seven_day_pace_pct=$(awk -v u="$seven_day_pct" -v e="$elapsed_hrs" -v t="$total_hrs" 'BEGIN { p = u * t / e; if (p > 200) p = 200; printf "%.1f", p }')
        fi
    fi

    sd_pace_int=${seven_day_pace_pct%.*}
    seven_day_bar=$(build_bar "$seven_day_pct" "$bar_width" "$sd_pace_int" color_for_weekly_pace)
    seven_day_pct_color=$(color_for_weekly_pace "$sd_pace_int")
    seven_day_pct_fmt=$(printf "%3d" "$seven_day_pct")

    # Weekly pace projection (float internally, integer display, fixed 3-char width)
    if [ "$sd_pace_int" -le 0 ] 2>/dev/null; then
        sd_pace_int="$seven_day_pct"
    fi
    sd_proj_color=$(color_for_weekly_pace "$sd_pace_int")
    sd_pace_fmt=$(printf "%3s" "$sd_pace_int")
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
