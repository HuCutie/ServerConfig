#!/bin/bash

# Define color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Log function for standardized output
log() {
    local type="$1"
    local message="$2"
    case "$type" in
        "INFO") echo -e "${CYAN}[INFO] ${message}${NC}" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS] ${message}${NC}" ;;
        "WARNING") echo -e "${YELLOW}[WARNING] ${message}${NC}" ;;
        "ERROR") echo -e "${RED}[ERROR] ${message}${NC}" ;;
        *) echo -e "[LOG] ${message}" ;;
    esac
}

# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    log "ERROR" "This script must be run as root."
    exit 1
fi

# Function to mount disks
mountdisks() {
    # Output the result of fdisk -l
    fdisk -l

    # Prompt the user to input devices and mount points
    read -p "Enter devices (space-separated, e.g., /dev/nvme0n1 /dev/sda /dev/sdb): " -a devices
    read -p "Enter mount points (space-separated, e.g., /ssd /data /data1): " -a mount_points

    if [ ${#devices[@]} -ne ${#mount_points[@]} ]; then
        log "ERROR" "Device and mount point lists have different lengths."
        return 1
    fi

    for ((i=0; i<${#devices[@]}; i++)); do
        local device="${devices[$i]}"
        local mount_point="${mount_points[$i]}"

        # Prompt user to decide whether to format the device
        read -p "Do you want to format $device as ext4? (yes/no): " format_choice
        if [ "$format_choice" == "yes" ]; then
            echo "y" | mkfs -t ext4 "$device"
        elif [ "$format_choice" != "no" ]; then
            log "WARNING" "Invalid choice. Skipping formatting for $device."
            continue
        fi

        mkdir -p "$mount_point"
        chmod 777 "$mount_point"

        if grep -qs "$device" /proc/mounts; then
            log "WARNING" "$device is already mounted."
        else
            if blkid -s TYPE -o value "$device" | grep -q "^ext4$"; then
                local uuid
                uuid=$(blkid -s UUID -o value "$device")
                if grep -qs "$uuid" /etc/fstab; then
                    log "INFO" "UUID $uuid is already present in /etc/fstab. Skipping."
                else
                    cp /etc/fstab /etc/fstab.bak
                    echo "UUID=$uuid $mount_point ext4 defaults 0 0" >> /etc/fstab
                    mount "$device" "$mount_point"
                    log "SUCCESS" "Mounted $device at $mount_point with UUID $uuid"
                fi
            else
                log "ERROR" "$device is not formatted as ext4. Please format it accordingly."
            fi
        fi
    done
}


# Function to install Docker
installdocker() {
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg

    local docker_keyring="/etc/apt/keyrings/docker.asc"
    local docker_repository="https://download.docker.com/linux/ubuntu"
    local docker_architecture
    docker_architecture="$(dpkg --print-architecture)"
    local docker_codename
    docker_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")

    if [ ! -d "/etc/apt/keyrings" ]; then
        sudo install -m 0755 -d /etc/apt/keyrings
    fi

    if [ ! -f "$docker_keyring" ]; then
        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$docker_keyring"
        sudo chmod a+r "$docker_keyring"
    else
        log "INFO" "Keyring file '$docker_keyring' already exists. Skipping keyring setup."
    fi

    local repo_list="/etc/apt/sources.list.d/docker.list"
    if [ ! -f "$repo_list" ]; then
        echo "deb [arch=${docker_architecture} signed-by=${docker_keyring}] ${docker_repository} ${docker_codename} stable" | \
            sudo tee "$repo_list" > /dev/null
    else
        log "INFO" "Repository list file '$repo_list' already exists. Skipping repository setup."
    fi

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    log "SUCCESS" "Docker installation completed."
}

# Function to configure Docker
configdocker() {
    local file_path="/etc/docker/daemon.json"
    local content='{
        "data-root": "/ssd/docker",
        "exec-opts": ["native.cgroupdriver=cgroupfs"]
    }'

    [ ! -f "$file_path" ] && sudo touch "$file_path"
    echo "$content" | sudo tee "$file_path" > /dev/null
    log "INFO" "Configuration file '$file_path' has been created and updated."

    sudo systemctl daemon-reload
    sudo systemctl restart docker

    local distribution=$(. /etc/os-release && echo "$ID$VERSION_ID")
    local nvidia_key_url="https://nvidia.github.io/nvidia-docker/gpgkey"
    local nvidia_repo_url="https://nvidia.github.io/nvidia-docker/${distribution}/nvidia-docker.list"

    curl -s -L "$nvidia_key_url" | sudo apt-key add -
    curl -s -L "$nvidia_repo_url" | sudo tee /etc/apt/sources.list.d/nvidia-docker.list > /dev/null

    sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
    mv /etc/apt/sources.list.d/nvidia-docker.list nvidia-docker.list.bak

    sudo systemctl restart docker
    log "SUCCESS" "NVIDIA Docker support has been configured."
}

# Function to configure SSH
configssh() {
    local config_file="/etc/ssh/sshd_config"
    local max_sessions="MaxSessions"
    local max_startups="MaxStartups"
    local new_value="1000"

    update_config() {
        local parameter="$1"
        if grep -q "^$parameter" "$config_file"; then
            sed -i "/^$parameter/ s/#\?$parameter.*/$parameter $new_value/" "$config_file"
        else
            echo "$parameter $new_value" >> "$config_file"
        fi
    }

    update_config "$max_sessions"
    update_config "$max_startups"

    sudo systemctl restart ssh
    log "SUCCESS" "SSH configuration has been updated: $max_sessions and $max_startups set to $new_value"
}

# Function to create the 'dock' command
configdock() {
    local script_path="/usr/local/bin/dock"

    cat << 'EOF' > "$script_path"
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

printf "${GREEN}GPU 上的进程和对应的容器信息：${RESET}\n\n"

# 获取 GPU 数量
gpu_count=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)

for ((gpu=0; gpu<gpu_count; gpu++)); do
    # 获取当前 GPU 上的所有进程
    gpu_processes=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader --id=$gpu)

    # 检查是否有进程在当前 GPU 上运行
    if [ -z "$gpu_processes" ]; then
        continue
    fi

    # 获取当前 GPU 的显存信息
    mem_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits --id=$gpu)
    mem_total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits --id=$gpu)

    # 计算显存使用百分比
    mem_usage_percent=$(awk "BEGIN {printf \"%.1f\", ($mem_used/$mem_total)*100}")
    mem_used_gb=$(awk "BEGIN {printf \"%.2f\", $mem_used/1024}")
    mem_total_gb=$(awk "BEGIN {printf \"%.2f\", $mem_total/1024}")

    # 打印GPU的显存使用情况
    printf "${YELLOW}GPU ${gpu}（显存使用: ${mem_used_gb}GB/${mem_total_gb}GB ${mem_usage_percent}%%）：${RESET}\n"

    for pid in $gpu_processes; do
        if [ -e /proc/$pid/cgroup ]; then
            container_id=$(cat /proc/$pid/cgroup | grep -oP '/docker/\K.{12}')
            container_name=$(docker ps --no-trunc --format '{{.Names}}' --filter "id=$container_id")

            # 获取当前进程的显存使用
            gpu_mem_usage=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader --id=$gpu)
            gpu_mem_usage=$(echo "$gpu_mem_usage" | grep -w "$pid" | awk '{print $2}')
            gpu_mem_usage_gb=$(awk "BEGIN {printf \"%.2f\", $gpu_mem_usage/1024}")

            # 计算显存的使用百分比
            gpu_mem_usage_percent=$(awk "BEGIN {printf \"%.1f\", ($gpu_mem_usage/$mem_total)*100}")

            # 格式化输出
            container_info="无"
            if [ -n "$container_name" ]; then
                container_info=$container_name
            fi

            # 输出每个PID的显存使用情况
            printf "  PID: ${RED}%-8s${RESET} 容器: ${GREEN}%-25s${RESET}" "$pid" "$container_info"
            printf "  显存使用: ${BLUE}%-6sGB${RESET} (${gpu_mem_usage_percent}%%)\n" "$gpu_mem_usage_gb"
        else
            printf "  PID ${RED}%-8s${RESET} 进程不存在或已终止。\n" "$pid"
        fi
    done
    printf "\n"
done
EOF

    chmod +x "$script_path"
    log "SUCCESS" "Script has been installed and created at $script_path, now you can run the command 'dock'."
}

# Function to create the 'chowndir' command
configdirown() {
    local script_path="/usr/local/bin/chowndir"

    cat << 'EOF' > "$script_path"
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

process_directories() {
    local parent_dir="$1"
    echo -e "${CYAN}Processing directory: $parent_dir${NC}"
    if [ -d "$parent_dir" ]; then
        for dir in "$parent_dir"/*; do
            if [ -d "$dir" ]; then
                echo -e "${YELLOW}Found directory: $dir${NC}"
                owner=$(stat -c '%U' "$dir")
                echo -e "${CYAN}Current owner of $dir: $owner${NC}"
                echo -e "${CYAN}Changing ownership of $dir to $owner:$owner${NC}"
                chown -R "$owner:$owner" "$dir"
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}Successfully changed ownership of $dir to $owner:$owner${NC}"
                else
                    echo -e "${RED}Failed to change ownership of $dir${NC}"
                fi
            else
                echo -e "${RED}$dir is not a directory, skipping...${NC}"
            fi
        done
    else
        echo -e "${RED}$parent_dir does not exist.${NC}"
    fi
}

process_directories "/data"
process_directories "/data1"
EOF

    chmod +x "$script_path"
    log "SUCCESS" "Script has been installed and created at $script_path, now you can run command 'chowndir'."
}

# Function to install applications
installapps() {
    is_package_installed() {
        dpkg -l "$1" | grep -qE "^ii\s+$1"
    }

    install_package() {
        local package_name="$1"
        if ! is_package_installed "$package_name"; then
            log "INFO" "Installing $package_name..."
            sudo apt-get update
            sudo apt-get install -y "$package_name"
        else
            log "INFO" "$package_name already installed."
        fi
    }

    install_package vim
    install_package htop
    install_package git
    install_package neofetch
    sudo update-pciids
    install_package lolcat

    if ! command -v pip3 &> /dev/null; then
        log "INFO" "pip3 not installed, installing..."
        sudo apt update
        sudo apt install -y python3-pip
    else
        log "INFO" "pip3 installed."
    fi

    pip3 install bottle gpustat
    pip3 install --upgrade nvitop
    log "SUCCESS" "nvitop installed."

    install_package curl
    install_package wget
    install_package apt-transport-https

    if ! is_package_installed v2raya; then
        log "INFO" "Installing V2RayA..."
        curl -Ls https://mirrors.v2raya.org/go.sh | sudo bash
        wget -qO - https://apt.v2raya.org/key/public-key.asc | sudo tee /etc/apt/keyrings/v2raya.asc
        echo "deb [signed-by=/etc/apt/keyrings/v2raya.asc] https://apt.v2raya.org/ v2raya main" | sudo tee /etc/apt/sources.list.d/v2raya.list
        sudo apt update
        sudo apt install -y v2ray v2raya
        log "SUCCESS" "V2RayA installed."
    else
        log "INFO" "V2RayA already installed."
    fi

    install_package xfce4
    install_package xfce4-goodies
    install_package xrdp
    sudo systemctl start xrdp
    install_package vsftpd
}

# Function to create users
createusers() {
    local usernames=("hub" "huxg" "chendh" "chenq" "gaowc" "lijw" "lixx" "maopc" "tangps" "wangd" "wangxy" "xuy" "yangcx" "zhangt" "zouyt")
    local password="1341454644"

    for username in "${usernames[@]}"; do
        if id "$username" &>/dev/null; then
            log "INFO" "User $username already exists."
        else
            useradd -m -s /bin/bash "$username"
            echo "$username:$password" | chpasswd
            log "SUCCESS" "Created user: $username with password: $password"
        fi
    done
}

# Function to configure users
configusers() {
    local usernames=("hub" "huxg" "chendh" "chenq" "gaowc" "lijw" "lixx" "maopc" "tangps" "wangd" "wangxy" "xuy" "yangcx" "zhangt" "zouyt" "user")

    for username in "${usernames[@]}"; do
        if id "$username" &>/dev/null; then
            if groups "$username" | grep -qE '\bdocker\b'; then
                log "INFO" "User $username is already a member of the Docker group."
            else
                usermod -aG docker "$username"
                log "SUCCESS" "Added $username to Docker group"
            fi
        else
            log "WARNING" "User $username not found."
        fi
    done
}

# Function to create the 'neofetch' command with 'lolcat' output
configneofetch() {
    local file_path="/etc/profile.d/neofetch.sh"
    local content='#!/bin/sh
neofetch | lolcat'

    echo "$content" | sudo tee "$file_path" > /dev/null
    sudo chmod +x "$file_path"
    log "SUCCESS" "Neofetch script has been created at $file_path."
    return 0
}

# Main function
main() {
    while true; do
        echo "-------------------------------------"
        echo "        Script Menu Options           "
        echo "-------------------------------------"
        echo "1. Mount Disks"
        echo "2. Install Applications"
        echo "3. Configure SSH and Neoetch"
        echo "4. Create 'dock' and 'chowndir' Command"
        echo "5. Create Users"
        echo "6. Install Docker"
        echo "7. Configure Docker"
        echo "8. Configure Users"
        echo "0. Execute all functions and exit"
        echo "-------------------------------------"
        read -p "Enter your choice (0-9): " choice

        case "$choice" in
            1) log "INFO" "Mounting disks..."; mountdisks ;;
            2) log "INFO" "Installing applications..."; installapps ;;
            3) log "INFO" "Configuring SSH and neofetch..."; configssh; configneofetch;;
            4) log "INFO" "Creating 'dock' and 'chowndir' command..."; configdock;configdirown ;;
            5) log "INFO" "Creating users..."; createusers ;;
            6) log "INFO" "Installing Docker..."; installdocker ;;
            7) log "INFO" "Configuring Docker..."; configdocker ;;
            8) log "INFO" "Configuring users..."; configusers ;;
            0) log "INFO" "Executing all functions..."; main_functions; log "SUCCESS" "All functions executed successfully. Exiting..."; return ;;
            *) log "WARNING" "Invalid option. Please enter a number between 0 and 9." ;;
        esac
    done
}

# Function to execute all main functions
main_functions() {
    mountdisks
    installdocker
    configdocker
    configssh
    configdock
    configdirown
    installapps
    createusers
    configusers
    configneofetch
}

main