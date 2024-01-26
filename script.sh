#!/bin/bash

function mountdisks() {
    # 定义磁盘设备列表和对应的挂载点列表
    declare -a devices=("/dev/sda" "/dev/sdb" "/dev/nvme1n1")  # 替换为你的磁盘设备列表
    declare -a mount_points=("/data" "/data1" "/ssd")  # 替换为你的挂载点列表

    # 确保设备列表和挂载点列表长度相同
    if [ ${#devices[@]} -ne ${#mount_points[@]} ]; then
        echo "Error: Device and mount point lists have different lengths."
        exit 1
    fi

    # 循环处理每个磁盘
    for ((i=0; i<${#devices[@]}; i++)); do
        # 格式化硬盘为ext4格式，适用于初次执行
        # mkfs -t ext4 ${devices[$i]}

        device="${devices[$i]}"
        mount_point="${mount_points[$i]}"

        # 确保挂载点存在
        mkdir -p "$mount_point"

        # 检查磁盘是否已经挂载
        if grep -qs "$device" /proc/mounts; then
            echo "$device is already mounted."
        else
            # 检查是否为 ext4 文件系统，如果不是，可以根据需要添加其他文件系统类型
            if blkid -s TYPE -o value "$device" | grep -q "^ext4$"; then
                # 获取磁盘UUID
                uuid=$(blkid -s UUID -o value "$device")

                if [ -n "$uuid" ]; then
                    # 备份/etc/fstab文件
                    cp /etc/fstab /etc/fstab.bak

                    # 添加挂载项到/etc/fstab
                    echo "UUID=$uuid $mount_point ext4 defaults 0 0" >> /etc/fstab
                    mount "$device" "$mount_point"
                    echo "Mounted $device at $mount_point with UUID $uuid"
                else
                    echo "Failed to get UUID for $device"
                fi
            else
                echo "$device is not formatted as ext4. Please format it accordingly."
            fi
        fi
    done
}

function installdocker() {
    # Add Docker's official GPG key:
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg

    local docker_keyring="/etc/apt/keyrings/docker.gpg"
    local docker_repository="https://download.docker.com/linux/ubuntu"
    local docker_architecture="$(dpkg --print-architecture)"
    local docker_codename
    docker_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")

    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o "$docker_keyring"
    sudo chmod a+r "$docker_keyring"

    # Add the repository to Apt sources:
    echo "deb [arch=${docker_architecture} signed-by=${docker_keyring}] ${docker_repository} ${docker_codename} stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    echo "Docker installation and configuration completed."
}

function configdocker() {
    # Define the file path and content
    local file_path="/etc/docker/daemon.json"
    local content='{
        "data-root": "/ssd/docker",
        "exec-opts": ["native.cgroupdriver=cgroupfs"]
    }'

    # Check if the file already exists, and create it if not
    [ ! -f "$file_path" ] && sudo touch "$file_path"

    # Write the content to the file
    echo "$content" | sudo tee "$file_path" > /dev/null

    echo "Configuration file '$file_path' has been created and updated."

    # Restart Docker for changes to take effect
    sudo systemctl daemon-reload
    sudo systemctl restart docker

    # Add NVIDIA Docker support
    local distribution=$(. /etc/os-release && echo "$ID$VERSION_ID")
    local nvidia_key_url="https://nvidia.github.io/nvidia-docker/gpgkey"
    local nvidia_repo_url="https://nvidia.github.io/nvidia-docker/${distribution}/nvidia-docker.list"

    curl -s -L "$nvidia_key_url" | sudo apt-key add -
    curl -s -L "$nvidia_repo_url" | sudo tee /etc/apt/sources.list.d/nvidia-docker.list > /dev/null

    sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit

    # Backup NVIDIA Docker repository configuration
    mv /etc/apt/sources.list.d/nvidia-docker.list nvidia-docker.list.bak

    # Restart Docker for changes to take effect
    sudo systemctl restart docker

    echo "NVIDIA Docker support has been configured."
}

function configssh() {
    # 配置文件路径
    config_file="/etc/ssh/sshd_config"

    # 定义要设置的参数和值
    max_sessions="MaxSessions"
    max_startups="MaxStartups"
    new_value="1000"

    # 函数用于检查并更新配置行
    update_config() {
        local parameter="$1"
        if grep -q "^$parameter" "$config_file"; then
            # 如果存在该参数，使用sed命令修改行，去掉注释符号并追加配置
            sed -i "/^$parameter/ s/#\?$parameter.*/$parameter $new_value/" "$config_file"
        else
            # 如果不存在该参数，直接追加配置
            echo "$parameter $new_value" >> "$config_file"
        fi
    }

    # 检查并更新MaxSessions配置
    update_config "$max_sessions"

    # 检查并更新MaxStartups配置
    update_config "$max_startups"

    # 重启SSH服务
    sudo systemctl restart ssh

    echo "SSH configuration has been updated:"
    echo "$max_sessions set to $new_value"
    echo "$max_startups set to $new_value"
}

function configdock() {
    # 设置可执行文件路径
    script_path="/usr/local/bin/dock"

    # 创建可执行文件
    cat << 'EOF' > "$script_path"
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

read -p "请输入PID: " pid

container_id=$(cat /proc/$pid/cgroup | grep -oP '/docker/\K.{12}')
container_name=$(docker ps --no-trunc --format '{{.Names}}' --filter "id=$container_id")

if [ -n "$container_name" ]; then
    echo -e "PID ${RED}$pid${RESET} 所属的容器名称为: ${GREEN}$container_name${RESET}"
else
    echo -e "PID ${RED}$pid${RESET} 不属于任何容器."
fi
EOF

    # 添加执行权限
    chmod +x "$script_path"

    echo "Script has been installed and created at $script_path, now you can run command 'dock'."
}


function installapps() {
    # Function to check if a package is installed
    is_package_installed() {
        dpkg -l "$1" | grep -qE "^ii\s+$1"
    }

    # Install a package if it is not already installed
    install_package() {
        local package_name="$1"
        if ! is_package_installed "$package_name"; then
            echo "Installing $package_name..."
            sudo apt-get update
            sudo apt-get install -y "$package_name"
        else
            echo "$package_name already installed."
        fi
    }

    # Install vim, htop, git
    install_package vim
    install_package htop
    install_package git

    # Install pip3 if not installed
    if ! command -v pip3 &> /dev/null; then
        echo "pip3 not installed, installing..."
        sudo apt update
        sudo apt install -y python3-pip
    else
        echo "pip3 installed."
    fi

    # Upgrade nvitop
    pip3 install --upgrade nvitop
    echo "nvitop installed."

    # Install curl and wget
    install_package curl
    install_package wget

    # Install V2RayA dependencies
    install_package apt-transport-https
    install_package v2ray

    # Install V2RayA
    if ! is_package_installed v2raya; then
        echo "Installing V2RayA..."
        curl -Ls https://mirrors.v2raya.org/go.sh | sudo bash

        # Add the V2RayA repository
        wget -qO - https://apt.v2raya.org/key/public-key.asc | sudo tee /etc/apt/keyrings/v2raya.asc
        echo "deb [signed-by=/etc/apt/keyrings/v2raya.asc] https://apt.v2raya.org/ v2raya main" | sudo tee /etc/apt/sources.list.d/v2raya.list

        # Update package lists
        sudo apt update

        # Install V2RayA
        sudo apt install -y v2raya
        echo "V2RayA installed."
    else
        echo "V2RayA already installed."
    fi
}

function createusers() {
    # Specify the list of usernames
    local usernames=("hub" "huxg" "chendh" "chenq" "gaowc" "lijw" "lixx" "maopc" "tangps" "wangd" "wangxy" "xuy" "yangcx" "zhangt" "zouyt")
    # Common password for all users
    local password="1341454644"

    for username in "${usernames[@]}"; do
        # Check if the user already exists
        if id "$username" &>/dev/null; then
            echo "User $username already exists."
        else
            useradd -m -s /bin/bash "$username"
            echo "$username:$password" | chpasswd
            echo "Created user: $username with password: $password"
        fi
    done
}

function configusers() {
    # Specify the list of usernames
    local usernames=("hub" "huxg" "chendh" "chenq" "gaowc" "lijw" "lixx" "maopc" "tangps" "wangd" "wangxy" "xuy" "yangcx" "zhangt" "zouyt" "user")

    for username in "${usernames[@]}"; do
        if id "$username" &>/dev/null; then
            usermod -aG docker "$username"
            echo "Added $username to Docker group"
        else
            echo "User $username not found."
        fi
    done
}

function main()
{
    echo "Mounting disks..."
    # mountdisks
    echo "Completed"

    echo "Installing Docker engine..."
    installdocker
    echo "Completed"

    echo "Editing Docker configuration file..."
    configdocker
    echo "Completed"

    echo "Editing ssh configuration file..."
    configssh
    echo "Completed"

    echo "Creating dock command..."
    configdock
    echo "Completed"

    echo "Installing some apps..."
    installapps
    echo "Completed"

    echo "Creating and Editing users..."
    createusers
    configusers
    echo "Completed"
}

main