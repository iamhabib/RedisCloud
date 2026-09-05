#!/bin/bash
set -euo pipefail

source ./bash/utility.sh
source ./bash/docker.sh
source ./bash/nginx.sh

read_env_file
show_project_context

automation_options=(
    "Install Docker & Docker Compose"
    "Docker Compose Up"
    "Docker Compose Recreate (pull + force-recreate)"
    "Docker Compose Down"
    "Docker PS"
    "Goto Bash"
    "Delete All Unused Docker Images"
    "Set Swap Memory"
    "Create NGINX Server Block"
    "Delete NGINX Server Block"
    "Quit"
)

show_heading "Select Your Automation Option"
selected_automation=$(get_selection "${automation_options[@]}")

# Echo selection so logs/screenshots show what ran
if [ -n "$selected_automation" ] && [ "$selected_automation" != "Quit" ]; then
    show_heading "$selected_automation"
fi

case "$selected_automation" in
    "Install Docker & Docker Compose")
        install_docker_and_compose
        ;;
    "Docker Compose Up")
        fix_memory_overcommit
        install_nginx_if_not_installed
        docker_compose_up
        run_docker ps
        ;;
    "Docker Compose Recreate (pull + force-recreate)")
        fix_memory_overcommit
        install_nginx_if_not_installed
        docker_compose_recreate
        run_docker ps
        ;;
    "Docker Compose Down")
        docker_compose_down
        ;;
    "Docker PS")
        run_docker ps
        ;;
    "Goto Bash")
        CONTAINER_NAME="${ENV}_${APP_NAME}_redis"
        if [ "$(run_docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo false)" = "true" ]; then
            display "info" "Opening shell as root in ${CONTAINER_NAME}"
            # alpine images use sh; debian-based redis images also provide sh
            run_docker exec -u 0 -it "$CONTAINER_NAME" sh
        else
            display "error" "Container ${CONTAINER_NAME} is not running"
        fi
        ;;
    "Delete All Unused Docker Images")
        prune_unused_docker_images
        ;;
    "Set Swap Memory")
        setup_swap_memory
        ;;
    "Create NGINX Server Block")
        set_up_host_machine_nginx
        ;;
    "Delete NGINX Server Block")
        remove_host_machine_nginx
        ;;
    "Quit"|"")
        display "info" "Bye."
        ;;
    *)
        display "error" "Unknown option: ${selected_automation}"
        exit 1
        ;;
esac
