## 实现原理

本脚本采用 Shell 语言编写，通过条件判断、文件操作、系统命令及包管理工具，实现对服务器初始化过程的自动化配置。各模块的核心原理如下：

- **磁盘挂载**  
  使用 `lsblk` 和 `blkid` 识别未挂载的磁盘设备。若用户同意格式化，调用 `mkfs.ext4` 创建 ext4 文件系统，并通过 `UUID` 写入 `/etc/fstab` 实现系统启动自动挂载。

- **Docker 安装与配置**  
  借助系统包管理器（如 `apt`）安装 Docker 及其依赖工具，配置文件 `/etc/docker/daemon.json` 中设置 Docker 数据根目录（默认 `/ssd/docker`）。安装 NVIDIA Container Toolkit 以支持 GPU 加速容器运行。

- **SSH 配置优化**  
  修改 `/etc/ssh/sshd_config` 中的 `MaxStartups` 和 `MaxSessions` 参数，提升 SSH 并发连接数上限，并重启 `ssh` 服务以生效。

- **工具命令创建**
  - `dock`：封装 `nvidia-smi` 与 `docker ps`，通过匹配 GPU 占用进程和容器 PID，输出每个 GPU 被哪个容器使用。
  - `chowndir`：封装 `chown -R $USER:$USER $DIR` 命令，批量修复指定路径的文件所有权，常用于恢复共享数据集目录权限。

- **基础软件安装**  
  批量安装常用工具（如 `vim`、`htop`、`git`、`neofetch` 等）。通过安装 `xfce4` 和 `xrdp` 实现图形化远程桌面访问，使用 `vsftpd` 配置轻量级 FTP 服务。

- **用户管理**  
  使用循环结构批量创建用户账号，调用 `useradd` 创建账号，通过 `chpasswd` 设置统一初始密码，并为其赋予必要权限。

- **系统美化**  
  在 `/etc/profile.d` 中创建脚本，使终端登录时自动调用 `neofetch` 输出系统信息，并通过 `lolcat` 渲染彩色效果，提升用户体验。

---

该脚本采用菜单驱动式交互，核心逻辑通过 `case`-`esac` 分支语句实现。用户可选择执行全部配置或按需选择部分模块，提升部署灵活性和适配性。
