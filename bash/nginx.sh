#!/bin/bash

function install_nginx_if_not_installed() {

    # Check if nginx is already installed
    if dpkg -l | grep -q "^ii.*nginx" 2>/dev/null; then
        display "info" "Nginx is already installed."

    else
        display "info" "Nginx is not installed. Installing..."

        # Update package list
        if ! sudo apt update; then
            display "error" "Failed to update package list"
            return 1
        fi

        # Install FULL Nginx with stream support (IMPORTANT)
        if ! sudo apt install nginx-extras -y; then
            display "error" "Failed to install nginx-extras"
            return 1
        fi

        display "success" "Nginx (with stream support) installed successfully."
    fi

    # Ensure nginx is enabled and running
    if ! sudo systemctl enable nginx; then
        display "error" "Failed to enable Nginx service"
        return 1
    fi

    if ! sudo systemctl start nginx; then
        display "error" "Failed to start Nginx service"
        return 1
    fi

    # Verify stream module support (VERY IMPORTANT for your Redis setup)
    if ! nginx -V 2>&1 | grep -q stream; then
        display "error" "Nginx does NOT have stream module. Install nginx-extras or nginx-full."
        return 1
    fi


    if ! sudo chown -R $USER /etc/nginx/sites-available; then
        display "error" "Failed to set permissions for Nginx sites-available"
        return 1
    fi

    # -----------------------------
    # STREAM CONFIG AUTO-INJECT
    # -----------------------------

    local nginx_conf="/etc/nginx/nginx.conf"

    # 1. Ensure folder exists
    sudo mkdir -p /etc/nginx/stream-conf.d

    # 2. Check if stream block exists
    if ! grep -q "stream {" "$nginx_conf"; then

        display "info" "Adding stream block to nginx.conf"

        sudo sed -i '/http {/i stream {\
    include /etc/nginx/stream-conf.d/*.conf;\
}' "$nginx_conf"
    else
        display "info" "stream block already exists"
    fi

    # 3. Ensure include exists inside stream block
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

    # Test nginx
    if ! sudo nginx -t; then
        display "error" "Nginx config test failed"
        return 1
    fi

    sudo systemctl reload nginx

    display "success" "Nginx is installed and ready (stream module enabled)."
}

function remove_host_machine_nginx() {

    # Validate required variables
    if [ -z "${ENV}" ] || [ -z "${APP_NAME}" ] || [ -z "${REDIS_PORT}" ]; then
        display "error" "Required ENV, APP_NAME, REDIS_PORT are not set"
        return 1
    fi

    local nginx_file_name="${ENV}_${APP_NAME}.conf"

    # ✅ Correct path for stream configs
    local config_path="/etc/nginx/stream-conf.d/${nginx_file_name}"

    # Check if config exists
    if [ -f "${config_path}" ]; then
        if ! sudo rm -f "${config_path}"; then
            display "error" "Failed to remove ${config_path}"
            return 1
        fi
        display "info" "Removed Nginx stream config: ${config_path}"
    else
        display "info" "Nginx config not found: ${config_path}"
    fi

    # Test nginx config before reload
    if ! sudo nginx -t; then
        display "danger" "Nginx configuration test failed after removal"
        return 1
    fi

    # Reload nginx safely
    if ! sudo systemctl reload nginx; then
        sudo systemctl restart nginx
    fi

    display "success" "Nginx reloaded successfully after removal"
}

function set_up_host_machine_nginx() {

    # Validate required variables
    if [ -z "${ENV}" ] || [ -z "${APP_NAME}" ] || [ -z "${REDIS_PORT}" ]; then
        display "error" "Required ENV, APP_NAME, REDIS_PORT are not set"
        return 1
    fi

    # Install nginx if needed
    if ! install_nginx_if_not_installed; then
        display "error" "Failed to install Nginx"
        return 1
    fi

    # Ensure stream module exists (optional safety check)
    if ! nginx -V 2>&1 | grep -q stream; then
        display "error" "Nginx stream module not available"
        return 1
    fi

    local nginx_file_name="${ENV}_${APP_NAME}.conf"
    local template_path="./bash/reverse_proxy.conf"
    local destination_path="/etc/nginx/stream-conf.d/${nginx_file_name}"

    # Check template
    if [ ! -f "${template_path}" ]; then
        display "danger" "Template file not found: ${template_path}"
        return 1
    fi

    # Generate config
    if ! sudo sed \
        -e "s/{{ENV}}/${ENV}/g" \
        -e "s/{{APP_NAME}}/${APP_NAME}/g" \
        -e "s/{{REDIS_PORT}}/${REDIS_PORT}/g" \
        "${template_path}" | sudo tee "${destination_path}" > /dev/null; then
        display "danger" "Failed to create Nginx stream config"
        return 1
    fi

    display "success" "Nginx stream config created at ${destination_path}"

    # Test nginx config
    if ! sudo nginx -t; then
        display "danger" "Nginx configuration test failed"
        return 1
    fi

    # Reload nginx
    if ! sudo systemctl reload nginx; then
        sudo systemctl restart nginx
    fi

    display "success" "Nginx reloaded successfully"
}