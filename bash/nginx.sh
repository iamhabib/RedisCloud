#!/bin/bash

function reload_host_nginx() {
    if ! sudo nginx -t; then
        display "danger" "Nginx configuration test failed"
        return 1
    fi

    if sudo systemctl reload nginx; then
        display "success" "Nginx reloaded with new configuration"
        return 0
    fi

    display "warning" "Nginx reload failed, trying restart..."
    if ! sudo systemctl restart nginx; then
        display "danger" "Failed to reload/restart Nginx"
        return 1
    fi

    display "success" "Nginx restarted with new configuration"
}

function install_nginx_if_not_installed() {
    # Prefer detecting a working nginx binary; fall back to dpkg package check
    if command -v nginx >/dev/null 2>&1 || dpkg -s nginx >/dev/null 2>&1 || dpkg -s nginx-extras >/dev/null 2>&1; then
        display "info" "Nginx is already installed."
    else
        display "info" "Nginx is not installed. Installing..."

        if ! sudo apt update; then
            display "error" "Failed to update package list"
            return 1
        fi

        # nginx-extras includes the stream module needed for Redis TCP proxy
        if ! sudo apt install nginx-extras -y; then
            display "error" "Failed to install nginx-extras"
            return 1
        fi

        display "success" "Nginx (with stream support) installed successfully."
    fi

    if ! sudo systemctl enable nginx; then
        display "error" "Failed to enable Nginx service"
        return 1
    fi

    if ! sudo systemctl start nginx; then
        display "error" "Failed to start Nginx service"
        return 1
    fi

    if ! nginx -V 2>&1 | grep -q stream; then
        display "error" "Nginx does NOT have stream module. Install nginx-extras or nginx-full."
        return 1
    fi

    local target_user
    target_user="$(get_login_user)"
    if ! sudo chown -R "${target_user}" /etc/nginx/sites-available 2>/dev/null; then
        display "warning" "Could not set ownership on /etc/nginx/sites-available (continuing)"
    fi

    # -----------------------------
    # STREAM CONFIG AUTO-INJECT
    # -----------------------------

    local nginx_conf="/etc/nginx/nginx.conf"

    sudo mkdir -p /etc/nginx/stream-conf.d

    if ! grep -q "stream {" "$nginx_conf"; then
        display "info" "Adding stream block to nginx.conf"

        sudo sed -i '/http {/i stream {\
    include /etc/nginx/stream-conf.d/*.conf;\
}' "$nginx_conf"
    else
        display "info" "stream block already exists"
    fi

    if grep -q "stream {" "$nginx_conf"; then
        if ! grep -q "stream-conf.d" "$nginx_conf"; then
            display "info" "Adding stream include path"

            sudo sed -i '/stream {/,/}/ {
                /include \/etc\/nginx\/stream-conf.d\/\*\.conf/! {
                    /stream {/a\    include /etc/nginx/stream-conf.d/*.conf;
                }
            }' "$nginx_conf"
        else
            display "info" "stream include already configured"
        fi
    fi

    if ! reload_host_nginx; then
        return 1
    fi

    display "success" "Nginx is installed and ready (stream module enabled)."
}

function sed_escape() {
    # Escape characters that are special in sed replacement when using | as delimiter
    printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'
}

function write_host_nginx_stream_config() {
    local template_path="$1"
    local destination_path="$2"
    local env_val app_name redis_port

    env_val="$(sed_escape "${ENV}")"
    app_name="$(sed_escape "${APP_NAME}")"
    redis_port="$(sed_escape "${REDIS_PORT}")"

    if ! sudo sed \
        -e "s|{{ENV}}|${env_val}|g" \
        -e "s|{{APP_NAME}}|${app_name}|g" \
        -e "s|{{REDIS_PORT}}|${redis_port}|g" \
        "${template_path}" | sudo tee "${destination_path}" > /dev/null; then
        display "danger" "Failed to create Nginx stream config"
        return 1
    fi

    display "success" "Nginx stream config created at ${destination_path}"
}

function remove_host_machine_nginx() {
    if [ -z "${ENV:-}" ] || [ -z "${APP_NAME:-}" ] || [ -z "${REDIS_PORT:-}" ]; then
        display "error" "Required ENV, APP_NAME, REDIS_PORT are not set"
        return 1
    fi

    local nginx_file_name="${ENV}_${APP_NAME}_${REDIS_PORT}.conf"
    local config_path="/etc/nginx/stream-conf.d/${nginx_file_name}"

    if [ -f "${config_path}" ]; then
        if ! sudo rm -f "${config_path}"; then
            display "error" "Failed to remove ${config_path}"
            return 1
        fi
        display "info" "Removed Nginx stream config: ${config_path}"
    else
        display "info" "Nginx config not found: ${config_path}"
    fi

    reload_host_nginx
}

function set_up_host_machine_nginx() {
    if [ -z "${ENV:-}" ] || [ -z "${APP_NAME:-}" ] || [ -z "${REDIS_PORT:-}" ]; then
        display "error" "Required ENV, APP_NAME, REDIS_PORT are not set"
        return 1
    fi

    if ! install_nginx_if_not_installed; then
        display "error" "Failed to install Nginx"
        return 1
    fi

    if ! nginx -V 2>&1 | grep -q stream; then
        display "error" "Nginx stream module not available"
        return 1
    fi

    local nginx_file_name="${ENV}_${APP_NAME}_${REDIS_PORT}.conf"
    local template_path="./bash/reverse_proxy.conf"
    local destination_path="/etc/nginx/stream-conf.d/${nginx_file_name}"

    if [ ! -f "${template_path}" ]; then
        display "danger" "Template file not found: ${template_path}"
        return 1
    fi

    if [ -f "${destination_path}" ]; then
        display "warning" "Nginx stream config already exists at ${destination_path}."
        display "info" "Overwrite this file?"
        if ! get_user_choice; then
            display "info" "Keeping existing Nginx stream config."
        elif ! write_host_nginx_stream_config "${template_path}" "${destination_path}"; then
            return 1
        fi
    elif ! write_host_nginx_stream_config "${template_path}" "${destination_path}"; then
        return 1
    fi

    if [ ! -f "${destination_path}" ]; then
        display "danger" "Failed to create Nginx stream config!"
        return 1
    fi

    reload_host_nginx
}
