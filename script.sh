#!/bin/bash

function mountdisks()
{
    # 定义磁盘设备列表和对应的挂载点列表
    mkdir /data
    mkdir /data1
    mkdir /ssd
    devices=("/dev/sda" "/dev/sdb" "/dev/nvme1n1")  # 替换为你的磁盘设备列表
    mount_points=("/data" "/data1" "/ssd")  # 替换为你的挂载点列表

    # 确保设备列表和挂载点列表长度相同
    if [ ${#devices[@]} -ne ${#mount_points[@]} ]; then
        echo "Error: Device and mount point lists have different lengths."
        exit 1
    fi

    # 循环处理每个磁盘
    for ((i=0; i<${#devices[@]}; i++)); do
        # mkfs -t ext4 ${devices[$i]}
        device_to_mount="${devices[$i]}"
        mount_point="${mount_points[$i]}"
        mount ${devices[$i]} ${mount_points[$i]}
        # 获取磁盘UUID
        uuid=$(blkid -s UUID -o value "$device_to_mount")

        if [ -n "$uuid" ]; then
            # 备份/etc/fstab文件
            cp /etc/fstab /etc/fstab.bak

            # 添加挂载项到/etc/fstab
            echo "UUID=$uuid $mount_point ext4 defaults 0 0" >> /etc/fstab
            echo "Added entry to /etc/fstab for $device_to_mount with UUID $uuid"
        else
            echo "Failed to get UUID for $device_to_mount"
        fi
    done
}

function installdocker()
{
    # Add Docker's official GPG key:
    sudo apt-get update
    sudo apt-get install ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # Add the repository to Apt sources:
    echo \
    "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update

    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    echo "Docker installation and configuration completed."
}

function configdocker()
{
    # Define the file path and content
    file_path="/etc/docker/daemon.json"
    content='{
        "data-root": "/ssd/docker",
        "exec-opts": ["native.cgroupdriver=cgroupfs"]
    }'
    # Check if the file already exists, and create it if not
    if [ ! -f "$file_path" ]; then
        sudo touch "$file_path"
    fi

    # Write the content to the file
    echo "$content" | sudo tee "$file_path"

    echo "Configuration file '$file_path' has been created and updated."

    # Restart Docker for changes to take effect
    sudo systemctl daemon-reload
    sudo systemctl restart docker

    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
    curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list
    sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
    mv /etc/apt/sources.list.d/nvidia-docker.list nvidia-docker.list.bak
    sudo systemctl restart docker
}

function configssh()
{
    # 配置文件路径
    config_file="/etc/ssh/sshd_config"

    # 检查是否存在MaxSessions行
    if grep -q "^MaxSessions" "$config_file"; then
        # 如果存在MaxSessions行，使用sed命令修改行，去掉注释符号并追加配置
        sed -i '/^MaxSessions/ s/#\?MaxSessions.*/MaxSessions 1000/' "$config_file"
    else
        # 如果不存在MaxSessions行，直接追加配置
        echo "MaxSessions 1000" >> "$config_file"
    fi

    # 检查是否存在MaxStartups行
    if grep -q "^MaxStartups" "$config_file"; then
        # 如果存在MaxStartups行，使用sed命令修改行，去掉注释符号并追加配置
        sed -i '/^MaxStartups/ s/#\?MaxStartups.*/MaxStartups 1000/' "$config_file"
    else
        # 如果不存在MaxStartups行，直接追加配置
        echo "MaxStartups 1000" >> "$config_file"
    fi

    # 重启SSH服务
    systemctl restart ssh

    echo "MaxSessions has been set $new_max_sessions"
    echo "MaxStartups has been set $new_max_startups"
}

function configdock()
{
    # 检查是否有足够权限执行
    if [ "$EUID" -ne 0 ]; then
        echo "请使用sudo运行此脚本"
        exit
    fi

    # 设置可执行文件路径
    script_path="/usr/local/bin/dock"

    # 创建可执行文件
    cat << EOF > "$script_path"
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

read -p "请输入PID: " pid

container_id=\$(cat /proc/\$pid/cgroup | grep -oP '/docker/\K.{12}')
container_name=\$(docker ps --no-trunc --format '{{.Names}}' --filter "id=\$container_id")

echo -e "PID \${RED}\$pid\${RESET} 所属的容器名称为: \${GREEN}\$container_name\${RESET}"
EOF

    # 添加执行权限
    chmod +x "$script_path"

    echo "Script has been installed and created at $script_path, now you can run command 'dock'."
}

function installapps()
{
    echo "Installing vim..."
    apt install -y vim
    echo "vim installed."

    echo "Installing htop..."
    apt install -y htop
    echo "thop installed."

    echo "Installing git..."
    apt install -y git
    echo "git installed."

    # 检查是否已安装 pip3
    if ! command -v pip3 &> /dev/null; then
        echo "pip3 not installed, installing..."
        sudo apt update
        sudo apt install -y python3-pip
    else
        echo "pip3 installed."
    fi
    pip3 install --upgrade nvitop
    echo "nvitop installed."

    # Function to check if a package is installed
    is_package_installed() {
        dpkg -l "$1" | grep -qE "^ii\s+$1"
    }

    # Check if curl is installed
    if ! is_package_installed curl; then
        echo "Installing curl..."
        sudo apt-get update
        sudo apt-get install -y curl
    fi

    # Check if wget is installed
    if ! is_package_installed wget; then
        echo "Installing wget..."
        sudo apt-get update
        sudo apt-get install -y wget
    fi

    # Install V2RayA
    curl -Ls https://mirrors.v2raya.org/go.sh | sudo bash
    sudo systemctl disable v2ray --now

    # Check if wget is installed
    if ! is_package_installed apt-transport-https; then
        echo "Installing apt-transport-https..."
        sudo apt-get update
        sudo apt-get install -y apt-transport-https
    fi

    # Add the V2RayA repository
    wget -qO - https://apt.v2raya.org/key/public-key.asc | sudo tee /etc/apt/keyrings/v2raya.asc
    echo "deb [signed-by=/etc/apt/keyrings/v2raya.asc] https://apt.v2raya.org/ v2raya main" | sudo tee /etc/apt/sources.list.d/v2raya.list

    # Update package lists
    sudo apt update

    # Install V2RayA
    sudo apt install v2raya

    echo "v2raya installed."
}

function createusers()
{
    # Specify the list of usernames
    usernames=("hub" "chendh" "chenq" "gaowc" "lijw" "lixx" "maopc" "tangps" "wangd" "xuy" "yangcx" "zhangt")
    # Common password for all users
    password="1341454644"

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

function configusers()
{
    # Specify the list of usernames
    usernames=("hub" "huxg" "chendh" "chenq" "gaowc" "lijw" "lixx" "maopc" "tangps" "wangd" "wangxy" "xuy" "yangcx" "zhangt" "zouyt")

    for username in "${usernames[@]}"; do
        usermod -aG docker $username
        echo "Added $username to Docker group"
    done
}

function main()
{
    # echo "Mounting disks..."
    # mountdisks
    # echo "Completed"

    # echo "Installing Docker engine..."
    # installdocker
    # echo "Completed"

    # echo "Editing Docker configuration file..."
    # configdocker
    # echo "Completed"

    # echo "Editing ssh configuration file..."
    # configssh
    # echo "Completed"

    echo "Creating dock command..."
    configdock
    echo "Completed"

    # echo "Installing some apps..."
    # installapps
    # echo "Completed"

    # echo "Creating and Editing users..."
    # createusers
    # configusers
    # echo "Completed"
}

main
