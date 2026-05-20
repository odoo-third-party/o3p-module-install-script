#!/usr/bin/env bash
set -Eeuo pipefail

O3P_INSTALLER_VERSION="v2.0.0"
SCRIPT_NAME="run.sh"
WORKDIR=""
CONFIG_SOURCE=""
CONFIG_FILE=""
CONFIG_ARG=""
SELECTOR_ARG=""
DATABASE_ARG=""
ADDONS_DIR_ARG=""
FORCE_ARG=""
DRY_RUN=0
YES=0
NON_INTERACTIVE=0
INSTALL_ALL=0
NO_RESTART=0
NO_REFRESH=0
KEEP_WORKDIR=0
STAGE_NO=0

declare -a INST_KIND INST_PID INST_USER INST_CMD INST_CONFIG INST_BIN INST_RUNNER
declare -a INST_UNIT INST_CID INST_CNAME INST_VERSION INST_SCORE INST_ADDONS_ARG
declare -a INSTANCE_KEYS

usage() {
    cat <<EOF
O3P module installer $O3P_INSTALLER_VERSION

Usage:
  $SCRIPT_NAME --config FILE_OR_URL [options]

Options:
  --config FILE_OR_URL     Required. Local .o3p.json file or http/https URL.
  --instance SELECTOR      auto, all, a 1-based list number, pid:PID, or container:ID.
  --all                    Install into every discovered Odoo instance.
  --database DB            Override the database from the .o3p.json file.
  --addons-dir PATH        Override addons directory detection.
  --force                  Replace existing target addon directories without prompting.
  --yes                    Accept non-destructive prompts.
  --non-interactive        Never prompt; auto-select the highest confidence instance.
  --dry-run                Show discovery and planned actions without copying/restarting.
  --no-restart             Do not restart Odoo after copying modules.
  --no-refresh             Do not refresh Odoo app lists, even when database is known.
  --keep-workdir           Keep temporary files for debugging.
  -h, --help               Show this help.

Example:
  curl -fsSL https://raw.githubusercontent.com/odoo-third-party/o3p-module-install-script/main/sources/run.sh \\
    | bash -s -- --config "https://raw.githubusercontent.com/odoo-third-party/o3p-future-module/main/o3p-future-module.o3p.json"
EOF
}

cleanup() {
    if [[ "$KEEP_WORKDIR" -eq 0 && -n "$WORKDIR" && -d "$WORKDIR" ]]; then
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT

fail() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf '  ! %s\n' "$*" >&2
}

info() {
    printf '  - %s\n' "$*"
}

stage() {
    STAGE_NO=$((STAGE_NO + 1))
    printf '\n[%02d] %s\n' "$STAGE_NO" "$*"
    printf '%s\n' "----------------------------------------"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required."
}

with_timeout() {
    local seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
    else
        "$@"
    fi
}

json_get() {
    jq -r "$1 // empty" "$CONFIG_FILE"
}

json_bool() {
    local expr="$1"
    local value
    value="$(jq -r "$expr // false" "$CONFIG_FILE")"
    [[ "$value" == "true" || "$value" == "1" || "$value" == "yes" ]]
}

shell_quote() {
    printf "%q" "$1"
}

trim() {
    local value="$*"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                CONFIG_ARG="${2:-}"
                [[ -n "$CONFIG_ARG" ]] || fail "Missing value for --config."
                shift 2
                ;;
            --instance)
                SELECTOR_ARG="${2:-}"
                [[ -n "$SELECTOR_ARG" ]] || fail "Missing value for --instance."
                shift 2
                ;;
            --all)
                INSTALL_ALL=1
                shift
                ;;
            --database)
                DATABASE_ARG="${2:-}"
                [[ -n "$DATABASE_ARG" ]] || fail "Missing value for --database."
                shift 2
                ;;
            --addons-dir)
                ADDONS_DIR_ARG="${2:-}"
                [[ -n "$ADDONS_DIR_ARG" ]] || fail "Missing value for --addons-dir."
                shift 2
                ;;
            --force)
                FORCE_ARG="true"
                shift
                ;;
            --yes|-y)
                YES=1
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --no-restart)
                NO_RESTART=1
                shift
                ;;
            --no-refresh)
                NO_REFRESH=1
                shift
                ;;
            --keep-workdir)
                KEEP_WORKDIR=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "Unknown option: $1"
                ;;
        esac
    done

    [[ -n "$CONFIG_ARG" ]] || fail "Pass --config FILE_OR_URL."
}

load_config() {
    stage "Loading install parameters"
    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/o3p-v2.XXXXXX")"
    CONFIG_SOURCE="$CONFIG_ARG"

    if [[ "$CONFIG_ARG" =~ ^https?:// ]]; then
        need_cmd curl
        CONFIG_FILE="$WORKDIR/config.o3p.json"
        info "Downloading config: $CONFIG_ARG"
        curl -fsSL "$CONFIG_ARG" -o "$CONFIG_FILE"
    else
        CONFIG_FILE="$CONFIG_ARG"
        [[ -f "$CONFIG_FILE" ]] || fail "Config file does not exist: $CONFIG_FILE"
    fi

    jq empty "$CONFIG_FILE" >/dev/null || fail "Config is not valid JSON: $CONFIG_SOURCE"

    local name schema module_count
    name="$(json_get '.name')"
    schema="$(json_get '.schema_version')"
    module_count="$(jq -r '(.modules // []) | length' "$CONFIG_FILE")"
    [[ "$module_count" -gt 0 ]] || fail "Config must contain at least one item in .modules[]."
    jq -e '
        (.modules // []) | all(.[]; 
            ((.name // "") != "") and
            (((.github_repository // .github // .repo // .repository // ."github repository") // "") != "")
        )
    ' "$CONFIG_FILE" >/dev/null || fail "Every .modules[] item must include name and github_repository."

    info "Config: ${name:-unnamed package}"
    info "Schema: ${schema:-2}"
    info "Modules: $module_count"
}

load_cmdline_args() {
    local cmdline_file="$1"
    CMD_ARGS=()
    while IFS= read -r -d '' arg; do
        CMD_ARGS+=("$arg")
    done < "$cmdline_file" || true
}

arg_value() {
    local wanted_short="$1"
    local wanted_long="$2"
    local index arg
    for index in "${!CMD_ARGS[@]}"; do
        arg="${CMD_ARGS[$index]}"
        if [[ "$arg" == "$wanted_short" || "$arg" == "$wanted_long" ]]; then
            printf '%s' "${CMD_ARGS[$((index + 1))]:-}"
            return 0
        fi
        if [[ "$arg" == "$wanted_long="* ]]; then
            printf '%s' "${arg#*=}"
            return 0
        fi
    done
}

looks_like_odoo_path() {
    local value="$1"
    local base
    base="$(basename "$value")"
    [[ "$base" == "odoo" || "$base" == "odoo-bin" || "$value" == *"/odoo-bin"* ]]
}

extract_odoo_command() {
    local runner="" bin="" first base arg
    first="${CMD_ARGS[0]:-}"
    base="$(basename "$first")"

    if looks_like_odoo_path "$first"; then
        bin="$first"
    elif [[ "$base" == python* ]]; then
        for arg in "${CMD_ARGS[@]:1:8}"; do
            [[ "$arg" == -* ]] && continue
            if looks_like_odoo_path "$arg"; then
                runner="$first"
                bin="$arg"
                break
            fi
        done
    fi

    if [[ -z "$bin" ]]; then
        for arg in "${CMD_ARGS[@]:0:10}"; do
            if looks_like_odoo_path "$arg"; then
                bin="$arg"
                break
            fi
        done
    fi

    if [[ -n "$bin" && "$bin" != /* ]]; then
        bin="$(command -v "$bin" 2>/dev/null || printf '%s' "$bin")"
    fi
    if [[ -n "$runner" && "$runner" != /* ]]; then
        runner="$(command -v "$runner" 2>/dev/null || printf '%s' "$runner")"
    fi

    DETECTED_RUNNER="$runner"
    DETECTED_BIN="$bin"
}

systemd_unit_for_pid() {
    local pid="$1"
    command -v systemctl >/dev/null 2>&1 || return 1
    local unit main_pid
    while read -r unit _; do
        [[ -n "$unit" ]] || continue
        main_pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
        if [[ "$main_pid" == "$pid" ]]; then
            printf '%s' "$unit"
            return 0
        fi
    done < <(systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null || true)
    return 1
}

container_id_for_pid() {
    local pid="$1"
    command -v docker >/dev/null 2>&1 || return 1

    local cid
    cid="$(sed -nE 's|.*/([0-9a-f]{64})(\.scope)?$|\1|p; s|.*/docker-([0-9a-f]{64})\.scope$|\1|p' "/proc/$pid/cgroup" 2>/dev/null | head -n 1 || true)"
    if [[ -n "$cid" ]]; then
        docker inspect "$cid" >/dev/null 2>&1 && {
            docker inspect --format '{{.Id}}' "$cid" 2>/dev/null || printf '%s' "$cid"
            return 0
        }
    fi

    local container container_pid
    for container in $(docker ps -q 2>/dev/null || true); do
        container_pid="$(docker inspect --format '{{.State.Pid}}' "$container" 2>/dev/null || true)"
        if [[ "$container_pid" == "$pid" ]]; then
            docker inspect --format '{{.Id}}' "$container" 2>/dev/null || printf '%s' "$container"
            return 0
        fi
    done
    return 1
}

container_name() {
    docker inspect --format '{{.Name}}' "$1" 2>/dev/null | sed 's|^/||'
}

instance_key() {
    local kind="$1" pid="$2" config="$3" bin="$4" unit="$5" cid="$6"
    if [[ -n "$cid" ]]; then
        printf 'docker|%s' "$cid"
    elif [[ -n "$unit" ]]; then
        printf 'systemd|%s' "$unit"
    elif [[ -n "$config" || -n "$bin" ]]; then
        printf '%s|%s|%s' "$kind" "$config" "$bin"
    else
        printf '%s|%s' "$kind" "$pid"
    fi
}

instance_key_exists() {
    local key="$1" index
    for index in "${!INSTANCE_KEYS[@]}"; do
        [[ "${INSTANCE_KEYS[$index]}" == "$key" ]] && return 0
    done
    return 1
}

instance_config_exists() {
    local config="$1" index
    [[ -n "$config" ]] || return 1
    for index in "${!INST_CONFIG[@]}"; do
        [[ "${INST_CONFIG[$index]}" == "$config" ]] && return 0
    done
    return 1
}

add_instance() {
    local kind="$1" pid="$2" user="$3" cmd="$4" config="$5" bin="$6" runner="$7"
    local unit="$8" cid="$9" cname="${10}" version="${11}" score="${12}" addons_arg="${13}"
    local key index

    key="$(instance_key "$kind" "$pid" "$config" "$bin" "$unit" "$cid")"
    instance_key_exists "$key" && return 0

    index="${#INST_KIND[@]}"
    INSTANCE_KEYS[$index]="$key"
    INST_KIND[$index]="$kind"
    INST_PID[$index]="$pid"
    INST_USER[$index]="$user"
    INST_CMD[$index]="$cmd"
    INST_CONFIG[$index]="$config"
    INST_BIN[$index]="$bin"
    INST_RUNNER[$index]="$runner"
    INST_UNIT[$index]="$unit"
    INST_CID[$index]="$cid"
    INST_CNAME[$index]="$cname"
    INST_VERSION[$index]="$version"
    INST_SCORE[$index]="$score"
    INST_ADDONS_ARG[$index]="$addons_arg"
}

detect_host_processes() {
    local proc pid cmd lowered config addons_arg user bin runner unit cid cname kind version score key

    for proc in /proc/[0-9]*; do
        [[ -r "$proc/cmdline" ]] || continue
        pid="${proc##*/}"
        cmd="$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null || true)"
        [[ -n "$cmd" ]] || continue
        lowered="${cmd,,}"
        [[ "$lowered" == *odoo* ]] || continue
        [[ "$lowered" != *"$SCRIPT_NAME"* ]] || continue
        [[ "$lowered" != *"o3p-v2"* ]] || continue
        [[ "$lowered" != postgres:* && "$lowered" != *" postgres:"* ]] || continue
        [[ "$lowered" != node\ * && "$lowered" != *" node "* ]] || continue

        load_cmdline_args "$proc/cmdline"
        extract_odoo_command
        bin="$DETECTED_BIN"
        runner="$DETECTED_RUNNER"
        [[ -n "$bin" || "$lowered" == *odoo-bin* || "$lowered" == *" odoo "* ]] || continue

        config="$(arg_value "-c" "--config")"
        addons_arg="$(arg_value "" "--addons-path")"
        user="$(stat -c '%U' "$proc" 2>/dev/null || true)"
        unit="$(systemd_unit_for_pid "$pid" || true)"
        cid="$(container_id_for_pid "$pid" || true)"
        cname=""
        kind="process"
        score=70

        if [[ -n "$unit" ]]; then
            kind="systemd"
            score=$((score + 30))
        fi
        if [[ -n "$cid" ]]; then
            kind="docker"
            cname="$(container_name "$cid")"
            score=$((score + 35))
        fi
        [[ -n "$config" ]] && score=$((score + 10))
        [[ -n "$addons_arg" ]] && score=$((score + 10))

        key="$(instance_key "$kind" "$pid" "$config" "$bin" "$unit" "$cid")"
        instance_key_exists "$key" && continue
        [[ "$kind" == "process" ]] && instance_config_exists "$config" && continue

        version="$(detect_instance_version_values "$kind" "$bin" "$runner" "$cid")"
        add_instance "$kind" "$pid" "$user" "$cmd" "$config" "$bin" "$runner" "$unit" "$cid" "$cname" "$version" "$score" "$addons_arg"
    done
}

detect_docker_containers() {
    command -v docker >/dev/null 2>&1 || return 0

    local line cid cid_full name image command combined host_pid cmd config addons_arg version key
    while IFS=$'\t' read -r cid name image command; do
        [[ -n "$cid" ]] || continue
        combined="${name} ${image} ${command}"
        [[ "${combined,,}" == *odoo* ]] || continue
        [[ "${combined,,}" != *postgres* ]] || continue
        cid_full="$(docker inspect --format '{{.Id}}' "$cid" 2>/dev/null || printf '%s' "$cid")"
        host_pid="$(docker inspect --format '{{.State.Pid}}' "$cid" 2>/dev/null || true)"
        key="$(instance_key "docker" "$host_pid" "" "" "" "$cid_full")"
        instance_key_exists "$key" && continue
        cmd="$(with_timeout 5s docker exec "$cid" sh -lc 'tr "\000" " " </proc/1/cmdline 2>/dev/null || true' 2>/dev/null || true)"
        config="$(with_timeout 5s docker exec "$cid" sh -lc 'tr "\000" "\n" </proc/1/cmdline | awk "prev==1{print; exit} /^-c$|^--config$/{prev=1; next} /^--config=/{sub(/^--config=/, \"\"); print; exit}"' 2>/dev/null || true)"
        addons_arg="$(with_timeout 5s docker exec "$cid" sh -lc 'tr "\000" "\n" </proc/1/cmdline | awk "prev==1{print; exit} /^--addons-path$/{prev=1; next} /^--addons-path=/{sub(/^--addons-path=/, \"\"); print; exit}"' 2>/dev/null || true)"
        version="$(detect_instance_version_values "docker" "" "" "$cid")"
        add_instance "docker" "$host_pid" "" "${cmd:-$combined}" "$config" "" "" "" "$cid_full" "$name" "$version" 85 "$addons_arg"
    done < <(docker ps --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Command}}' 2>/dev/null || true)
}

detect_path_odoo() {
    local candidate bin version
    for candidate in \
        "$(command -v odoo 2>/dev/null || true)" \
        "$(command -v odoo-bin 2>/dev/null || true)" \
        /usr/bin/odoo /usr/bin/odoo-bin /usr/local/bin/odoo /usr/local/bin/odoo-bin \
        /opt/odoo/odoo-bin /opt/odoo/odoo/odoo-bin /home/odoo/odoo-bin; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        bin="$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")"
        version="$(detect_instance_version_values "path" "$bin" "" "")"
        add_instance "path" "" "" "$bin --version" "" "$bin" "" "" "" "" "$version" 30 ""
    done
}

detect_instance_version_values() {
    local kind="$1" bin="$2" runner="$3" cid="$4"
    local output=""

    if [[ "$kind" == "docker" && -n "$cid" ]]; then
        output="$(with_timeout 8s docker exec "$cid" sh -lc 'for c in odoo odoo-bin /usr/bin/odoo /usr/bin/odoo-bin /opt/odoo/odoo-bin; do command -v "$c" >/dev/null 2>&1 || [ -x "$c" ] || continue; "$c" --version 2>/dev/null && exit 0; done' 2>/dev/null | head -n 1 || true)"
    elif [[ -n "$bin" ]]; then
        if [[ -n "$runner" && -x "$runner" && -f "$bin" ]]; then
            output="$(with_timeout 8s "$runner" "$bin" --version 2>/dev/null | head -n 1 || true)"
        elif [[ -x "$bin" ]]; then
            output="$(with_timeout 8s "$bin" --version 2>/dev/null | head -n 1 || true)"
        fi
    fi

    printf '%s' "$output"
}

discover_instances() {
    stage "Discovering live Odoo instances"
    INST_KIND=()
    INSTANCE_KEYS=()

    detect_host_processes
    detect_docker_containers
    detect_path_odoo

    if [[ "${#INST_KIND[@]}" -eq 0 ]]; then
        fail "No Odoo instances were discovered. Start Odoo or pass --addons-dir with an installed odoo command in PATH."
    fi

    local index display version detail
    for index in "${!INST_KIND[@]}"; do
        display=$((index + 1))
        version="${INST_VERSION[$index]:-unknown version}"
        detail="${INST_KIND[$index]}"
        [[ -n "${INST_PID[$index]}" ]] && detail="$detail pid=${INST_PID[$index]}"
        [[ -n "${INST_UNIT[$index]}" ]] && detail="$detail unit=${INST_UNIT[$index]}"
        [[ -n "${INST_CNAME[$index]}" ]] && detail="$detail container=${INST_CNAME[$index]}"
        info "[$display] $detail"
        info "    version: $version"
        [[ -n "${INST_CONFIG[$index]}" ]] && info "    config: ${INST_CONFIG[$index]}"
        [[ -n "${INST_ADDONS_ARG[$index]}" ]] && info "    addons from args: ${INST_ADDONS_ARG[$index]}"
    done
    return 0
}

select_instances() {
    stage "Selecting target instance"
    local selector selected=() index best best_score answer
    selector="${SELECTOR_ARG:-$(json_get '.odoo.selector')}"
    [[ -n "$selector" ]] || selector="auto"
    [[ "$INSTALL_ALL" -eq 1 ]] && selector="all"

    if [[ "$selector" == "all" ]]; then
        for index in "${!INST_KIND[@]}"; do
            selected+=("$index")
        done
    elif [[ "$selector" =~ ^[0-9]+$ ]]; then
        index=$((selector - 1))
        [[ "$index" -ge 0 && "$index" -lt "${#INST_KIND[@]}" ]] || fail "Instance selector out of range: $selector"
        selected+=("$index")
    elif [[ "$selector" == pid:* ]]; then
        for index in "${!INST_KIND[@]}"; do
            [[ "${INST_PID[$index]}" == "${selector#pid:}" ]] && selected+=("$index")
        done
    elif [[ "$selector" == container:* ]]; then
        for index in "${!INST_KIND[@]}"; do
            [[ "${INST_CID[$index]}" == "${selector#container:}" || "${INST_CNAME[$index]}" == "${selector#container:}" ]] && selected+=("$index")
        done
    elif [[ "$selector" == "auto" ]]; then
        if [[ "${#INST_KIND[@]}" -eq 1 ]]; then
            selected+=(0)
        elif [[ "$NON_INTERACTIVE" -eq 0 && -t 0 && "$YES" -eq 0 ]]; then
            printf 'Choose an Odoo instance number, or "all": '
            read -r answer
            if [[ "$answer" == "all" ]]; then
                for index in "${!INST_KIND[@]}"; do selected+=("$index"); done
            elif [[ "$answer" =~ ^[0-9]+$ ]]; then
                index=$((answer - 1))
                [[ "$index" -ge 0 && "$index" -lt "${#INST_KIND[@]}" ]] || fail "Instance selector out of range: $answer"
                selected+=("$index")
            else
                fail "Invalid selection: $answer"
            fi
        else
            best=0
            best_score=-1
            for index in "${!INST_KIND[@]}"; do
                if [[ "${INST_SCORE[$index]}" -gt "$best_score" ]]; then
                    best="$index"
                    best_score="${INST_SCORE[$index]}"
                fi
            done
            selected+=("$best")
            warn "Multiple Odoo instances found; selected #$((best + 1)) because the session is non-interactive."
        fi
    else
        fail "Unsupported instance selector: $selector"
    fi

    [[ "${#selected[@]}" -gt 0 ]] || fail "No instance matched selector: $selector"
    SELECTED_INSTANCES=("${selected[@]}")

    for index in "${SELECTED_INSTANCES[@]}"; do
        info "Selected #$((index + 1)): ${INST_KIND[$index]} ${INST_VERSION[$index]:-unknown version}"
    done
}

split_paths() {
    local raw="$1"
    local item
    SPLIT_PATHS=()
    raw="${raw//[$'\n\r']/}"
    IFS=',' read -ra SPLIT_PATHS <<< "$raw"
    for item in "${!SPLIT_PATHS[@]}"; do
        SPLIT_PATHS[$item]="$(trim "${SPLIT_PATHS[$item]}")"
    done
}

config_addons_paths_host() {
    local config="$1"
    [[ -n "$config" && -f "$config" ]] || return 0
    sed -nE 's/^[[:space:]]*addons_path[[:space:]]*=[[:space:]]*//p' "$config" | tail -n 1
}

config_addons_paths_docker() {
    local cid="$1" config="$2"
    [[ -n "$cid" && -n "$config" ]] || return 0
    with_timeout 5s docker exec "$cid" sh -lc "test -f $(shell_quote "$config") && sed -nE 's/^[[:space:]]*addons_path[[:space:]]*=[[:space:]]*//p' $(shell_quote "$config") | tail -n 1" 2>/dev/null || true
}

collect_logs() {
    local index="$1"
    LOG_FILES=()
    local config="${INST_CONFIG[$index]}"
    local unit="${INST_UNIT[$index]}"
    local cid="${INST_CID[$index]}"
    local log_file=""
    local file

    if [[ -n "$config" && -f "$config" ]]; then
        log_file="$(sed -nE 's/^[[:space:]]*logfile[[:space:]]*=[[:space:]]*//p; s/^[[:space:]]*log_file[[:space:]]*=[[:space:]]*//p' "$config" | tail -n 1 || true)"
        [[ -n "$log_file" && -f "$log_file" ]] && LOG_FILES+=("$log_file")
    fi

    for file in /var/log/odoo/*.log /var/log/*odoo*.log /var/log/odoo/odoo-server.log; do
        [[ -f "$file" ]] && LOG_FILES+=("$file")
    done

    if [[ -n "$unit" && -n "$(command -v journalctl 2>/dev/null || true)" ]]; then
        file="$WORKDIR/journal-$index.log"
        journalctl -u "$unit" --no-pager -n 3000 > "$file" 2>/dev/null || true
        [[ -s "$file" ]] && LOG_FILES+=("$file")
    fi

    if [[ -n "$cid" && -n "$(command -v docker 2>/dev/null || true)" ]]; then
        file="$WORKDIR/docker-$index.log"
        with_timeout 8s docker logs --tail 3000 "$cid" > "$file" 2>&1 || true
        [[ -s "$file" ]] && LOG_FILES+=("$file")
    fi
    return 0
}

paths_from_logs() {
    local file match dir raw
    LOG_PATHS=()
    for file in "${LOG_FILES[@]:-}"; do
        while IFS= read -r raw; do
            raw="${raw#*[}"
            raw="${raw%]*}"
            raw="${raw//\'/}"
            raw="${raw//\"/}"
            split_paths "$raw"
            for match in "${SPLIT_PATHS[@]}"; do
                [[ "$match" == /* ]] && LOG_PATHS+=("$match")
            done
        done < <(grep -Eio 'addons paths?:[[:space:]]*\[[^]]+\]|addons paths?:[[:space:]]*[^[:cntrl:]]+' "$file" 2>/dev/null | sed -E 's/^addons paths?:[[:space:]]*//I' || true)

        while IFS= read -r match; do
            [[ -n "$match" ]] || continue
            dir="$(dirname "$(dirname "$match")")"
            LOG_PATHS+=("$dir")
        done < <(grep -Eho '/[^[:space:]"'"'"']+/(base|web|mail|contacts|base_setup)/(__manifest__|__openerp__)\.py' "$file" 2>/dev/null || true)
    done
    return 0
}

path_has_core_host() {
    local path="$1" module
    for module in base web mail contacts base_setup; do
        [[ -f "$path/$module/__manifest__.py" || -f "$path/$module/__openerp__.py" ]] && return 0
    done
    return 1
}

path_has_core_docker() {
    local cid="$1" path="$2"
    with_timeout 5s docker exec "$cid" sh -lc "for m in base web mail contacts base_setup; do test -f $(shell_quote "$path")/\$m/__manifest__.py || test -f $(shell_quote "$path")/\$m/__openerp__.py && exit 0; done; exit 1" >/dev/null 2>&1
}

add_candidate_path() {
    local path="$1" source="$2" score="$3"
    local i
    [[ -n "$path" ]] || return 0
    path="${path%/}"
    for i in "${!CAND_PATHS[@]}"; do
        if [[ "${CAND_PATHS[$i]}" == "$path" ]]; then
            if [[ "$score" -gt "${CAND_SCORES[$i]}" ]]; then
                CAND_SCORES[$i]="$score"
                CAND_SOURCES[$i]="$source"
            fi
            return 0
        fi
    done
    CAND_PATHS+=("$path")
    CAND_SOURCES+=("$source")
    CAND_SCORES+=("$score")
}

common_addons_candidates() {
    local candidate
    for candidate in \
        /usr/lib/python*/dist-packages/odoo/addons \
        /usr/local/lib/python*/dist-packages/odoo/addons \
        /usr/lib/odoo/addons \
        /opt/odoo/odoo/addons \
        /opt/odoo*/odoo/addons \
        /mnt/extra-addons \
        /var/lib/odoo/addons/*; do
        [[ -d "$candidate" ]] && add_candidate_path "$candidate" "common filesystem" 30
    done
    return 0
}

docker_map_path_to_host() {
    local cid="$1" cpath="$2"
    local best_dest="" best_src="" src dest suffix
    while IFS='|' read -r src dest; do
        [[ -n "$src" && -n "$dest" ]] || continue
        if [[ "$cpath" == "$dest" || "$cpath" == "$dest/"* ]]; then
            if [[ "${#dest}" -gt "${#best_dest}" ]]; then
                best_dest="$dest"
                best_src="$src"
            fi
        fi
    done < <(docker inspect --format '{{range .Mounts}}{{println .Source "|" .Destination}}{{end}}' "$cid" 2>/dev/null || true)

    [[ -n "$best_dest" ]] || return 1
    suffix="${cpath#"$best_dest"}"
    printf '%s%s' "$best_src" "$suffix"
}

resolve_addons_dir() {
    local index="$1"
    local override="$2"
    local kind="${INST_KIND[$index]}"
    local cid="${INST_CID[$index]}"
    local raw path score best=-1 best_i="" config_paths

    CAND_PATHS=()
    CAND_SOURCES=()
    CAND_SCORES=()
    INSTALL_MODE="host"
    INSTALL_ADDONS_DIR=""
    INSTALL_HOST_ADDONS_DIR=""

    if [[ -n "$override" ]]; then
        add_candidate_path "$override" "override" 200
    fi

    if [[ -n "${INST_ADDONS_ARG[$index]}" ]]; then
        split_paths "${INST_ADDONS_ARG[$index]}"
        for path in "${SPLIT_PATHS[@]}"; do
            add_candidate_path "$path" "process arguments" 100
        done
    fi

    if [[ "$kind" == "docker" && -n "$cid" ]]; then
        config_paths="$(config_addons_paths_docker "$cid" "${INST_CONFIG[$index]}")"
    else
        config_paths="$(config_addons_paths_host "${INST_CONFIG[$index]}")"
    fi
    if [[ -n "$config_paths" ]]; then
        split_paths "$config_paths"
        for path in "${SPLIT_PATHS[@]}"; do
            add_candidate_path "$path" "odoo config" 90
        done
    fi

    collect_logs "$index"
    paths_from_logs
    for path in "${LOG_PATHS[@]:-}"; do
        add_candidate_path "$path" "odoo logs" 120
    done

    common_addons_candidates

    for path in "${!CAND_PATHS[@]}"; do
        raw="${CAND_PATHS[$path]}"
        score="${CAND_SCORES[$path]}"
        if [[ "$kind" == "docker" && -n "$cid" ]]; then
            if path_has_core_docker "$cid" "$raw"; then
                score=$((score + 25))
            fi
            if mapped="$(docker_map_path_to_host "$cid" "$raw" 2>/dev/null || true)" && [[ -n "$mapped" && -d "$mapped" ]]; then
                score=$((score + 15))
            fi
        elif path_has_core_host "$raw"; then
            score=$((score + 25))
        fi
        CAND_SCORES[$path]="$score"
        if [[ "$score" -gt "$best" ]]; then
            best="$score"
            best_i="$path"
        fi
    done

    [[ -n "$best_i" ]] || fail "Could not determine addons directory for selected instance #$((index + 1)). Pass --addons-dir."

    INSTALL_ADDONS_DIR="${CAND_PATHS[$best_i]}"
    if [[ "$kind" == "docker" && -n "$cid" ]]; then
        INSTALL_MODE="docker"
        if mapped="$(docker_map_path_to_host "$cid" "$INSTALL_ADDONS_DIR" 2>/dev/null || true)" && [[ -n "$mapped" && -d "$mapped" ]]; then
            INSTALL_MODE="host"
            INSTALL_HOST_ADDONS_DIR="$mapped"
        fi
    else
        INSTALL_HOST_ADDONS_DIR="$INSTALL_ADDONS_DIR"
    fi

    info "Addons directory: $INSTALL_ADDONS_DIR (${CAND_SOURCES[$best_i]}, score ${CAND_SCORES[$best_i]})"
    if [[ "$INSTALL_MODE" == "host" && "$INSTALL_HOST_ADDONS_DIR" != "$INSTALL_ADDONS_DIR" ]]; then
        info "Host mount: $INSTALL_HOST_ADDONS_DIR"
    fi
    if [[ "${#LOG_FILES[@]}" -gt 0 ]]; then
        info "Log sources inspected: ${#LOG_FILES[@]}"
    else
        warn "No Odoo logs were readable; used config/process/common path evidence."
    fi
}

version_series() {
    local text="$1"
    sed -nE 's/.*[^0-9]([0-9]+)\.([0-9]+)(\.[0-9]+)?.*/\1.\2/p' <<< "$text" | head -n 1
}

version_major() {
    local text="$1"
    sed -nE 's/.*[^0-9]([0-9]+)\.([0-9]+).*/\1/p' <<< "$text" | head -n 1
}

branch_exists() {
    local repo="$1" branch="$2"
    git ls-remote --exit-code --heads "$repo" "$branch" >/dev/null 2>&1
}

select_module_branch() {
    local repo="$1" requested="$2" version="$3"
    local series major candidate

    if [[ -n "$requested" && "$requested" != "auto" ]]; then
        printf '%s' "$requested"
        return 0
    fi

    series="$(version_series "$version")"
    major="$(version_major "$version")"
    for candidate in "$series" "${major}.0" "$major" main master; do
        [[ -n "$candidate" ]] || continue
        if branch_exists "$repo" "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done
}

reference_addon_host() {
    local addons="$1" module
    for module in base web mail contacts base_setup; do
        [[ -d "$addons/$module" ]] && {
            printf '%s' "$addons/$module"
            return 0
        }
    done
    find "$addons" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null || true
}

match_permissions_host() {
    local addons="$1" target="$2"
    local ref ref_file
    ref="$(reference_addon_host "$addons")"
    [[ -n "$ref" && -d "$ref" ]] || {
        warn "Could not find a reference addon for permissions in $addons."
        return 0
    }
    ref_file="$(find "$ref" -type f -print -quit 2>/dev/null || true)"
    chown -R --reference="$ref" "$target" 2>/dev/null || warn "Could not match owner from $ref."
    chmod --reference="$ref" "$target" 2>/dev/null || true
    if [[ -n "$ref_file" ]]; then
        find "$target" -type f -exec chmod --reference="$ref_file" {} + 2>/dev/null || true
    fi
}

install_module_host() {
    local source="$1" addons="$2" dest_name="$3" force="$4"
    local target="$addons/$dest_name"

    if [[ -e "$target" ]]; then
        if confirm_replace "$target" "$force"; then
            if [[ "$DRY_RUN" -eq 1 ]]; then
                info "Would remove existing addon: $target"
            else
                info "Removing existing addon: $target"
            fi
            [[ "$DRY_RUN" -eq 1 ]] || rm -rf "$target"
        fi
    fi

    [[ "$DRY_RUN" -eq 1 ]] && info "Would copy addon to $target" || info "Copying addon to $target"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        cp -a "$source" "$target"
        match_permissions_host "$addons" "$target"
    fi
}

install_module_docker() {
    local source="$1" cid="$2" addons="$3" dest_name="$4" force="$5"
    local target="$addons/$dest_name"

    if docker exec "$cid" sh -lc "test -e $(shell_quote "$target")" >/dev/null 2>&1; then
        if confirm_replace "$target" "$force"; then
            if [[ "$DRY_RUN" -eq 1 ]]; then
                info "Would remove existing addon in container: $target"
            else
                info "Removing existing addon in container: $target"
            fi
            [[ "$DRY_RUN" -eq 1 ]] || docker exec "$cid" rm -rf "$target"
        fi
    fi

    [[ "$DRY_RUN" -eq 1 ]] && info "Would copy addon into container $cid:$target" || info "Copying addon into container $cid:$target"
    [[ "$DRY_RUN" -eq 1 ]] || docker cp "$source" "$cid:$target"
}

confirm_replace() {
    local target="$1" force="$2"
    local answer

    if [[ "$force" == "true" ]]; then
        return 0
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "Existing addon found at $target; a real run would ask before replacing it."
        return 0
    fi
    if [[ -r /dev/tty && -w /dev/tty ]]; then
        printf 'Replace existing addon at %s? [y/N] ' "$target" > /dev/tty
        read -r answer < /dev/tty
    elif [[ -t 0 ]]; then
        printf 'Replace existing addon at %s? [y/N] ' "$target"
        read -r answer
    else
        fail "Addon already exists: $target. Run interactively to confirm replacement, or pass --force."
    fi

    case "${answer,,}" in
        y|yes)
            return 0
            ;;
        *)
            fail "Cancelled because addon already exists: $target"
            ;;
    esac
}

module_names_json() {
    jq -c '[.modules[].name]' "$CONFIG_FILE"
}

refresh_apps() {
    local index="$1" database="$2"
    local kind="${INST_KIND[$index]}" cid="${INST_CID[$index]}" user="${INST_USER[$index]}"
    local config="${INST_CONFIG[$index]}" bin="${INST_BIN[$index]}" runner="${INST_RUNNER[$index]}"
    local names py command quoted_config

    [[ -n "$database" ]] || return 0
    [[ "$NO_REFRESH" -eq 0 ]] || return 0

    names="$(module_names_json)"
    py="$WORKDIR/refresh-$index.py"
    cat > "$py" <<EOF
env["ir.module.module"].update_list()
for module_name in $names:
    module = env["ir.module.module"].search([("name", "=", module_name)], limit=1)
    if module and module.state == "installed":
        module.button_immediate_upgrade()
env.cr.commit()
EOF

    info "Refreshing app list for database $database"
    [[ "$DRY_RUN" -eq 1 ]] && return 0

    if [[ "$kind" == "docker" && -n "$cid" ]]; then
        quoted_config=""
        [[ -n "$config" ]] && quoted_config="-c $(shell_quote "$config")"
        docker exec -i "$cid" sh -lc "if command -v odoo >/dev/null 2>&1; then odoo shell $quoted_config -d $(shell_quote "$database") --no-http; else odoo-bin shell $quoted_config -d $(shell_quote "$database") --no-http; fi" < "$py"
        return 0
    fi

    [[ -n "$bin" ]] || {
        warn "No Odoo executable was found for app-list refresh."
        return 0
    }
    command=()
    [[ -n "$runner" ]] && command+=("$runner")
    command+=("$bin" "shell")
    [[ -n "$config" ]] && command+=("-c" "$config")
    command+=("-d" "$database" "--no-http")

    if [[ -n "$user" && "$(id -un)" != "$user" ]]; then
        if command -v runuser >/dev/null 2>&1; then
            runuser -u "$user" -- "${command[@]}" < "$py"
        elif command -v sudo >/dev/null 2>&1; then
            sudo -H -u "$user" -- "${command[@]}" < "$py"
        else
            warn "Need runuser or sudo to refresh app list as $user."
        fi
    else
        "${command[@]}" < "$py"
    fi
}

restart_instance() {
    local index="$1"
    [[ "$NO_RESTART" -eq 0 ]] || return 0
    [[ "$DRY_RUN" -eq 1 ]] && {
        info "Would restart selected Odoo instance."
        return 0
    }

    if [[ -n "${INST_UNIT[$index]}" ]]; then
        info "Restarting systemd unit ${INST_UNIT[$index]}"
        systemctl restart "${INST_UNIT[$index]}"
        return 0
    fi
    if [[ -n "${INST_CID[$index]}" ]]; then
        info "Restarting Docker container ${INST_CNAME[$index]:-${INST_CID[$index]}}"
        docker restart "${INST_CID[$index]}" >/dev/null
        return 0
    fi

    warn "No restart manager was detected for instance #$((index + 1)); restart Odoo manually."
}

install_for_instance() {
    local index="$1"
    local database addons_override force restart refresh module_count module_i
    local repo name selected_branch clone_dir source_dir
    local install_addons

    stage "Preparing instance #$((index + 1))"
    addons_override="${ADDONS_DIR_ARG:-$(json_get '.odoo.addons_dir')}"
    database="${DATABASE_ARG:-$(json_get '.database')}"
    force="${FORCE_ARG:-false}"
    [[ "$NO_RESTART" -eq 1 ]] && restart="false" || restart="$(jq -r '.install.restart // true' "$CONFIG_FILE")"
    [[ "$NO_REFRESH" -eq 1 ]] && refresh="false" || refresh="$(jq -r '.install.refresh_apps // true' "$CONFIG_FILE")"

    resolve_addons_dir "$index" "$addons_override"
    install_addons="$INSTALL_ADDONS_DIR"
    [[ "$INSTALL_MODE" == "host" && -n "$INSTALL_HOST_ADDONS_DIR" ]] && install_addons="$INSTALL_HOST_ADDONS_DIR"

    module_count="$(jq -r '.modules | length' "$CONFIG_FILE")"
    for ((module_i = 0; module_i < module_count; module_i++)); do
        name="$(jq -r ".modules[$module_i].name // empty" "$CONFIG_FILE")"
        repo="$(jq -r ".modules[$module_i].github_repository // .modules[$module_i].github // .modules[$module_i].repo // .modules[$module_i].repository // .modules[$module_i].\"github repository\" // empty" "$CONFIG_FILE")"
        [[ -n "$name" ]] || fail "modules[$module_i].name is required."
        [[ -n "$repo" ]] || fail "modules[$module_i].github_repository is required."

        stage "Installing module $name"
        selected_branch="$(select_module_branch "$repo" "auto" "${INST_VERSION[$index]}")"
        clone_dir="$WORKDIR/module-$module_i-$index"

        if [[ -n "$selected_branch" ]]; then
            info "Repository: $repo"
            info "Branch: $selected_branch"
            [[ "$DRY_RUN" -eq 1 ]] || git clone --depth 1 --branch "$selected_branch" "$repo" "$clone_dir"
        else
            info "Repository: $repo"
            info "Branch: default"
            [[ "$DRY_RUN" -eq 1 ]] || git clone --depth 1 "$repo" "$clone_dir"
        fi

        source_dir="$clone_dir/$name"
        [[ "$DRY_RUN" -eq 1 || -d "$source_dir" ]] || fail "Cloned repository does not contain addon folder matching module name: $name"

        if [[ "$INSTALL_MODE" == "docker" ]]; then
            install_module_docker "$source_dir" "${INST_CID[$index]}" "$INSTALL_ADDONS_DIR" "$name" "$force"
        else
            [[ -d "$install_addons" ]] || fail "Addons directory does not exist on host: $install_addons"
            [[ -w "$install_addons" ]] || fail "Addons directory is not writable: $install_addons"
            install_module_host "$source_dir" "$install_addons" "$name" "$force"
        fi
    done

    if [[ "$restart" == "true" ]]; then
        restart_instance "$index"
    else
        info "Restart skipped by config/arguments."
    fi

    if [[ "$refresh" == "true" && -n "$database" ]]; then
        refresh_apps "$index" "$database"
    elif [[ -z "$database" ]]; then
        warn "No database was provided; app list refresh was skipped."
    else
        info "App-list refresh skipped by config/arguments."
    fi
}

main() {
    parse_args "$@"
    need_cmd jq
    need_cmd git
    load_config
    discover_instances
    select_instances

    local index
    for index in "${SELECTED_INSTANCES[@]}"; do
        install_for_instance "$index"
    done

    stage "Done"
    info "O3P install run completed."
    [[ "$KEEP_WORKDIR" -eq 1 ]] && info "Workdir kept at: $WORKDIR"
    return 0
}

main "$@"
