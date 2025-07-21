#!/bin/bash

set -e

# --- Color & Logging Definitions ---
RESET='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'

log_info() { echo -e "\n${BLUE}--- $1 ---${RESET}"; }
log_sub_info() { echo -e "${CYAN}--- $1 ---${RESET}"; }
log_success() { echo -e "${GREEN}$1${RESET}"; }
log_error() { echo -e "${RED}Error: $1${RESET}"; }
log_warn() { echo -e "${YELLOW}Warning: $1${RESET}"; }
log_prompt() { echo -n -e "${YELLOW}$1${RESET}"; }

# --- Global Config ---
SHARED_COMPOSE_FILE="docker-compose.shared.yml"
N8N_COMPOSE_FILE="docker-compose.n8n.yml"
SHARED_STATE_FILE="n8n_local_data/.state/shared.state"
STATE_DIR="n8n_local_data/.state"

# --- Dependency check ---
check_dependencies() {
    local missing=0
    for dep in docker docker-compose git nc psql; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            log_error "Required dependency '$dep' is not installed or not in PATH."
            missing=1
        fi
    done
    if [ "$missing" -eq 1 ]; then
        exit 1
    fi
}

# --- Wait for a service to be healthy ---
wait_for_healthy_service() {
    local service_name=$1
    local project_name=$2
    log_sub_info "Waiting for '$service_name' in project '$project_name' to be healthy..."
    
    local attempt=0
    while [[ "$(docker-compose -f "$N8N_COMPOSE_FILE" -p "$project_name" ps -q "$service_name" | xargs docker inspect -f '{{.State.Health.Status}}' 2>/dev/null)" != "healthy" ]]; do
        if [ $attempt -ge 30 ]; then
            log_error "Service '$service_name' in project '$project_name' did not become healthy in time."
            docker-compose -f "$N8N_COMPOSE_FILE" -p "$project_name" logs "$service_name"
            exit 1
        fi
        attempt=$((attempt+1))
        echo "Waiting... (attempt ${attempt}/30)"
        sleep 5
    done
    
    log_success "Service '$service_name' is healthy."
}

# --- Instance State Helpers ---
get_instance_state_file() {
    echo "${STATE_DIR}/${SERVER_NAME}_${INSTANCE_NAME}.state"
}

save_instance_state() {
    mkdir -p "$STATE_DIR"
    (
        umask 077
        cat > "$(get_instance_state_file)" <<EOF
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
REDIS_DB="$REDIS_DB"
N8N_ENCRYPTION_KEY="$N8N_ENCRYPTION_KEY"
N8N_PORT="$N8N_PORT"
EOF
    )
}

load_instance_state() {
    local state_file
    state_file=$(get_instance_state_file)
    if [ -f "$state_file" ]; then
        # shellcheck disable=SC1090
        . "$state_file"
        return 0
    else
        return 1
    fi
}

# --- Shared Services Commands ---
command_shared() {
    local action="$1"
    case "$action" in
        up)
            log_info "Bringing up Shared Infrastructure (Postgres, Redis)"
            if [ -f "$SHARED_STATE_FILE" ]; then
                # shellcheck disable=SC1090
                . "$SHARED_STATE_FILE"
                export POSTGRES_PASSWORD
            else
                log_prompt "Enter a strong password for the main Postgres user: "
                read -s POSTGRES_PASSWORD
                echo
                if [[ -z "$POSTGRES_PASSWORD" ]]; then
                    log_error "Postgres password cannot be empty."
                    exit 1
                fi
                mkdir -p "$(dirname "$SHARED_STATE_FILE")"
                (umask 077; echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" > "$SHARED_STATE_FILE")
            fi
            export POSTGRES_PASSWORD
            docker-compose -f "$SHARED_COMPOSE_FILE" up -d
            log_success "Shared infrastructure is up."
            ;;
        down)
            log_info "Bringing down Shared Infrastructure"
            log_warn "This will stop Postgres and Redis, shutting down ALL n8n instances."
            log_prompt "Are you sure? (y/N) "
            read -r response
            if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
                docker-compose -f "$SHARED_COMPOSE_FILE" down --volumes
                rm -f "$SHARED_STATE_FILE"
                log_success "Shared infrastructure is down."
            else
                log_info "Cancelled."
            fi
            ;;
        logs) docker-compose -f "$SHARED_COMPOSE_FILE" logs -f ;;
        *) usage ;;
    esac
}

# --- Instance Commands ---
command_instance() {
    local action="$1"; shift
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -s|--server) SERVER_NAME="$2"; shift ;;
            -i|--instance) INSTANCE_NAME="$2"; shift ;;
            -p|--port) START_PORT="$2"; shift ;;
            -r|--repo) GITHUB_REPOSITORY="$2"; shift ;;
            -t|--token) GITHUB_TOKEN="$2"; shift ;;
            *) log_error "Unknown option for 'instance' command: $1"; usage ;;
        esac
        shift
    done

    if [[ -z "$SERVER_NAME" || -z "$INSTANCE_NAME" ]]; then
        log_error "-s/--server and -i/--instance are required."
        usage
    fi
    
    local INSTANCE_PROJECT_NAME="${SERVER_NAME}_${INSTANCE_NAME}"

    case "$action" in
        up)
            log_info "Bringing up instance: $INSTANCE_PROJECT_NAME"
            if [ ! -f "$SHARED_STATE_FILE" ]; then
                log_error "Shared infrastructure not running. Run './deploy.sh shared up' first."
                exit 1
            fi
            # shellcheck disable=SC1090
            . "$SHARED_STATE_FILE"
            export PGPASSWORD=$POSTGRES_PASSWORD

            if ! load_instance_state; then
                log_info "No state file found. Provisioning new instance..."
                DB_NAME=$(echo "$INSTANCE_PROJECT_NAME" | tr '[:upper:]' '[:lower:]')
                DB_USER="$DB_NAME"
                DB_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
                psql -h localhost -U postgres -d postgres -c "CREATE DATABASE \"$DB_NAME\";"
                psql -h localhost -U postgres -d postgres -c "CREATE USER \"$DB_USER\" WITH PASSWORD '$DB_PASS';"
                psql -h localhost -U postgres -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO \"$DB_USER\";"
                
                local last_redis_db
                last_redis_db=$(grep "REDIS_DB" ${STATE_DIR}/*.state 2>/dev/null | sed 's/REDIS_DB=//' | sort -n | tail -1)
                REDIS_DB=$(( ${last_redis_db:-2} + 1 ))
                
                local port=${START_PORT:-5678}
                while ( nc -z 127.0.0.1 $port &>/dev/null ); do port=$((port + 1)); done
                N8N_PORT=$port
                
                N8N_ENCRYPTION_KEY=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
                
                save_instance_state
                log_success "Provisioned and saved new instance state."
            fi
            
            if [[ -z "$GITHUB_REPOSITORY" ]]; then
                log_error "-r/--repo is required for the 'up' command."
                usage
            fi
            if [[ -z "$GITHUB_TOKEN" ]]; then
                log_prompt "Please enter your GitHub Personal Access Token: "
                read -s GITHUB_TOKEN; echo
            fi

            # Export all variables for docker-compose
            export SERVER_NAME INSTANCE_NAME DB_NAME DB_USER DB_PASS REDIS_DB N8N_ENCRYPTION_KEY N8N_PORT
            
            log_info "Starting n8n services for '$INSTANCE_PROJECT_NAME'..."
            docker-compose -f "$N8N_COMPOSE_FILE" -p "$INSTANCE_PROJECT_NAME" up -d --remove-orphans

            log_info "Verifying service health..."
            wait_for_healthy_service "editor" "$INSTANCE_PROJECT_NAME"
            wait_for_healthy_service "webhook" "$INSTANCE_PROJECT_NAME"
            wait_for_healthy_service "worker" "$INSTANCE_PROJECT_NAME"
            
            log_success "Instance '$INSTANCE_PROJECT_NAME' is up and running on port $N8N_PORT."
            log_warn "DB User: $DB_USER | DB Pass: $DB_PASS | DB Name: $DB_NAME"
            ;;
        update)
            log_info "Updating instance: $SERVER_NAME/$INSTANCE_NAME"
            if ! load_instance_state; then
                log_error "No state file found for instance. Cannot update."
                exit 1
            fi

            log_sub_info "Pulling latest n8n image..."
            docker-compose -f "$N8N_COMPOSE_FILE" -p "$INSTANCE_PROJECT_NAME" pull editor webhook worker
            
            log_sub_info "Recreating n8n containers..."
            export SERVER_NAME INSTANCE_NAME DB_NAME DB_USER DB_PASS REDIS_DB N8N_ENCRYPTION_KEY N8N_PORT
            docker-compose -f "$N8N_COMPOSE_FILE" -p "$INSTANCE_PROJECT_NAME" up -d --remove-orphans

            log_info "Verifying service health after update..."
            wait_for_healthy_service "editor" "$INSTANCE_PROJECT_NAME"
            wait_for_healthy_service "webhook" "$INSTANCE_PROJECT_NAME"
            wait_for_healthy_service "worker" "$INSTANCE_PROJECT_NAME"
            
            log_success "Instance update complete."
            ;;
        status)
            log_info "Checking status of running n8n instances"
            docker ps --format "table {{.Names}}\t{{.State}}\t{{.Ports}}" | {
                printf "INSTANCE\t\t\tSTATUS\t\tPORT\n"
                printf "--------------------------------------------------------\n"
                
                found_any=0
                while IFS= read -r line; do
                    if [[ $line == editor_* ]]; then
                        found_any=1
                        name=$(echo "$line" | awk '{print $1}')
                        state=$(echo "$line" | awk '{print $2}')
                        ports=$(echo "$line" | awk '{print $3}')
                        instance_id=$(echo "$name" | sed -e 's/editor_//' -e 's/_/\//')
                        port=$(echo "$ports" | sed -n 's/.*:\([0-9]*\)->5678\/tcp.*/\1/p')
                        printf "%-30s\t%-10s\t%s\n" "$instance_id" "$state" "$port"
                    fi
                done

                if [ "$found_any" -eq 0 ]; then
                    log_warn "No running n8n instances found."
                fi
            }
            ;;
        list)
            log_info "Listing all known n8n instances (from state files)"
            printf "INSTANCE\t\t\tPORT\tDB_NAME\t\tREDIS_DB\n"
            printf "--------------------------------------------------------------------------\n"
            
            found_any=0
            for state_file in ${STATE_DIR}/*.state; do
                [ -e "$state_file" ] || continue
                if [[ "$(basename "$state_file")" == "shared.state" ]]; then continue; fi
                
                found_any=1
                instance_id=$(basename "$state_file" .state | sed 's/_/\//')
                # shellcheck disable=SC1090
                . "$state_file"
                printf "%-30s\t%-5s\t%-20s\t%s\n" "$instance_id" "$N8N_PORT" "$DB_NAME" "$REDIS_DB"
            done

            if [ "$found_any" -eq 0 ]; then
                log_warn "No known n8n instances found."
            fi
            ;;
        prune)
            log_info "Pruning orphaned instance volumes"
            
            declare -A known_volumes
            for state_file in ${STATE_DIR}/*.state; do
                [ -e "$state_file" ] || continue
                if [[ "$(basename "$state_file")" == "shared.state" ]]; then continue; fi
                
                local instance_id
                instance_id=$(basename "$state_file" .state)
                known_volumes["${instance_id}_n8n_data"]=1
                known_volumes["${instance_id}_repo_temp"]=1
            done

            found_any=0
            for volume in $(docker volume ls --format '{{.Name}}' | grep '_n8n_data\|_repo_temp'); do
                if [[ -z "${known_volumes[$volume]}" ]];
                then
                    found_any=1
                    log_warn "Orphaned volume found: $volume"
                    log_prompt "Delete this volume? (y/N) "
                    read -r response
                    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
                        docker volume rm "$volume"
                        log_success "Volume '$volume' deleted."
                    fi
                fi
            done

            if [ "$found_any" -eq 0 ]; then
                log_success "No orphaned instance volumes found."
            fi
            ;;
        backup)
            log_info "Backing up instance to Git: $SERVER_NAME/$INSTANCE_NAME"
            if [[ -z "$GITHUB_REPOSITORY" ]]; then
                log_error "-r/--repo is required for the 'backup' command."
                usage
            fi
            if [[ -z "$GITHUB_TOKEN" ]]; then
                log_prompt "Please enter your GitHub Personal Access Token: "
                read -s GITHUB_TOKEN; echo
            fi

            local REPO_TEMP_DIR="n8n_repo_temp_${INSTANCE_PROJECT_NAME}"
            local REPO_VOLUME="${INSTANCE_PROJECT_NAME}_repo_temp"
            rm -rf "$REPO_TEMP_DIR"
            log_sub_info "Cloning Git repository..."
            git clone --depth 1 "https://${GITHUB_TOKEN}@${GITHUB_REPOSITORY#https://}" "$REPO_TEMP_DIR"
            
            log_sub_info "Copying repository content to Docker volume '$REPO_VOLUME'..."
            docker run --rm -v "$REPO_VOLUME:/data" -v "$(pwd)/$REPO_TEMP_DIR:/source" alpine ash -c "rm -rf /data/* && cp -r /source/. /data/"
            
            local EXPORT_PATH_CONTAINER="/tmp/import_data/${SERVER_NAME}/${INSTANCE_NAME}"
            log_sub_info "Exporting live workflows from n8n..."
            docker-compose -f "$N8N_COMPOSE_FILE" -p "$INSTANCE_PROJECT_NAME" exec -u node -T editor n8n export:workflow --backup --output="${EXPORT_PATH_CONTAINER}/workflows"
            
            log_sub_info "Exporting live credentials from n8n..."
            log_warn "Credentials will be DECRYPTED. Handle the backup file with care."
            docker-compose -f "$N8N_COMPOSE_FILE" -p "$INSTANCE_PROJECT_NAME" exec -u node -T editor n8n export:credentials --all --decrypted --output="${EXPORT_PATH_CONTAINER}/credentials.json"
            
            log_sub_info "Copying exported data back from volume..."
            docker run --rm -v "$REPO_VOLUME:/data" -v "$(pwd)/$REPO_TEMP_DIR:/source" alpine ash -c "cp -r /data/. /source/"
            
            log_sub_info "Committing and pushing changes to Git..."
            (
                cd "$REPO_TEMP_DIR" || exit 1
                git config user.name "n8n-deploy-bot"
                git config user.email "bot@deploy.script"
                git add .
                if ! git diff-index --quiet HEAD; then
                    git commit -m "Backup from $SERVER_NAME/$INSTANCE_NAME on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    git push
                    log_success "Backup pushed to Git successfully."
                else
                    log_success "No changes detected. Git repository is already up-to-date."
                fi
            )
            rm -rf "$REPO_TEMP_DIR"
            ;;
        down)
            log_info "Bringing down instance: $SERVER_NAME/$INSTANCE_NAME"
            if load_instance_state; then
                export SERVER_NAME INSTANCE_NAME
                docker-compose -f "$N8N_COMPOSE_FILE" -p "$INSTANCE_PROJECT_NAME" down --volumes
                . "$SHARED_STATE_FILE"
                export PGPASSWORD=$POSTGRES_PASSWORD
                psql -h localhost -U postgres -d postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\";"
                psql -h localhost -U postgres -d postgres -c "DROP USER IF EXISTS \"$DB_USER\";"
                rm -f "$(get_instance_state_file)"
                log_success "Instance cleanup complete."
            else
                log_warn "No state file found. Assuming instance is already down."
            fi
            ;;
        logs)
            export SERVER_NAME INSTANCE_NAME
            docker-compose -f "$N8N_COMPOSE_FILE" -p "$INSTANCE_PROJECT_NAME" logs -f
            ;;
        *) usage ;;
    esac
}

# --- Usage ---
usage() {
    echo "Usage: $0 <command> [sub-command] [options]"
    echo "Commands:"
    echo "  shared <up|down|logs>"
    echo "  instance <up|down|logs|backup|status|list|update|prune> -s <server> -i <instance> ..."
    exit 1
}

# --- Main Script Logic ---
check_dependencies
COMMAND="$1"
shift || usage
case "$COMMAND" in
    shared) command_shared "$@" ;;
    instance) command_instance "$@" ;;
    *) usage ;;
esac 