#!/usr/bin/env bash
set -eo pipefail

echo "=========================================="
echo "开始执行 SM 初始化序列..."
echo "=========================================="

# === 步骤 0：环境变量探测与交互式防呆 ===
echo "[INFO] 步骤 0：校验核心运行上下文..."

# 核心参数获取函数 (变量名, 提示语, 是否为敏感信息, 是否允许为空)
require_env() {
    local var_name=$1
    local prompt_msg=$2
    local is_secret=$3
    local is_optional=$4

    # 利用间接引用 ${!var_name} 检查变量是否已赋值
    if [ -z "${!var_name}" ]; then
        while true; do
            if [ "$is_secret" = true ]; then
                read -rs -p "[交互补全] $prompt_msg " input_val
                echo "" # 换行
            else
                read -r -p "[交互补全] $prompt_msg " input_val
            fi

            if [ -n "$input_val" ]; then
                export "$var_name"="$input_val"
                break
            elif [ "$is_optional" = true ]; then
                export "$var_name"=""
                break
            else
                echo "[ERROR] 致命错误：$var_name 是底层组网或鉴权的核心依赖，绝不可为空！请重新输入。"
            fi
        done
    else
        if [ "$is_secret" = true ]; then
             echo "[OK] 环境变量已注入: $var_name (内容出于安全考量已隐藏)"
        else
             echo "[OK] 环境变量已注入: $var_name = ${!var_name}"
        fi
    fi
}

require_env GITHUB_USER "请输入 GitHub 用户名:" false false
require_env GITHUB_EMAIL "请输入 GitHub 邮箱:" false false
require_env GITHUB_REPO "请输入私有配置仓库名称:" false false
require_env TS_AUTHKEY "请输入 Tailscale AuthKey (输入时不可见):" true false
require_env TARGET_HOSTNAME "请输入目标系统主机名:" false false
require_env EX_HOSTNAME "请输入要接替的旧主机名 (全新安装请直接回车):" false true

# 执行主机名变更
hostnamectl set-hostname "$TARGET_HOSTNAME"
CURRENT_HOST=$(hostname)
if ! grep -q "$CURRENT_HOST" /etc/hosts; then
    echo -e "127.0.1.1\t$CURRENT_HOST" >> /etc/hosts
    echo "[INFO] 节点身份已确认为: $CURRENT_HOST，并已注入本地回环路由。"
else
    echo "[INFO] 节点身份已确认为: $CURRENT_HOST，本地路由已存在，跳过注入。"
fi

# ==========================================
# 阶段一：基础设施与底层防线（Root 特权域）
# ==========================================
echo "[INFO] 阶段一：铺设底层组件与绝对防线..."

export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get install -y \
    nftables fail2ban podman uidmap git curl build-essential zsh fuse-overlayfs slirp4netns dbus-user-session

# 部署组网总线 Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# 建立隔离空间：创建业务态用户 xerath
if ! id "xerath" &>/dev/null; then
    useradd -m -s /bin/zsh xerath
    echo "xerath ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/xerath
else
    # 如果用户已存在（灾备重跑），强制修改它的默认 Shell
    usermod -s /usr/bin/zsh xerath
fi

# 打破普通用户封印：内核解禁与后台常驻
sysctl -w net.ipv4.ip_unprivileged_port_start=80
echo "net.ipv4.ip_unprivileged_port_start=80" > /etc/sysctl.d/99-userns.conf
loginctl enable-linger xerath

# 启动底层组网节点
tailscale up --authkey="${TS_AUTHKEY}" --hostname="ts-node-${CURRENT_HOST}" --accept-dns=true --ssh  --advertise-exit-node
tailscale set --relay-server-port=40000
# 封堵传统后门：重塑防火墙与 SSH 策略
systemctl enable --now nftables
systemctl enable --now fail2ban

# ==========================================
# 阶段二 & 三 & 四：用户态业务接管与容器编排（普通用户域）
# ==========================================
echo "[INFO] 阶段二：特权移交与实体脚本空投..."

# 1. 构造普通用户态装配实体脚本 (Stage 1.5)
# 使用双引号 EOF：专门用来把 Root 层的环境变量硬编码“烧录”进去
cat << EOF > /tmp/xerath-init.sh
#!/usr/bin/env bash
set -eo pipefail
export GITHUB_USER="${GITHUB_USER}"
export GITHUB_EMAIL="${GITHUB_EMAIL}"
export GITHUB_REPO="${GITHUB_REPO}"
export CURRENT_HOST="${CURRENT_HOST}"
export EX_HOSTNAME="${EX_HOSTNAME}"
EOF

# 2. 追加核心业务逻辑
# 使用单引号 'EOF'：彻底冻结内部变量，阻止 Root 提前展开，把执行权 100% 留给 xerath
cat << 'EOF' >> /tmp/xerath-init.sh

echo "[INFO] 成功切入用户域，当前 HOME 为 $HOME"

# 步骤 5：密钥锻造
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"

if [ ! -f "$SSH_KEY_PATH" ]; then
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "key-ts-node-${CURRENT_HOST}"
fi

# 步骤 6：阻断式等待，要求物理人工介入
echo "================================================================="
echo -e "\033[1;33m[MANUAL ACTION REQUIRED] 需要手动配置 GitHub Deploy Key\033[0m"
echo "================================================================="
echo "请复制下方高亮显示的 SSH 公钥："
echo "-----------------------------------------------------------------"
echo -e "\033[1;32m$(cat "$SSH_KEY_PATH.pub")\033[0m"
echo "-----------------------------------------------------------------"
echo "👉 https://github.com/${GITHUB_USER}/${GITHUB_REPO}/settings/keys/new"
echo -e "\033[1;31m⚠️  致命提醒：务必勾选 'Allow write access'，否则 GitOps 灾备将暴毙！\033[0m"
echo ""

while true; do
    read -r -p "[等待确认] 公钥已添加并保存？请按 [Enter] 键继续执行..."
    break
done

echo "[INFO] 信任链握手确认，继续拉取私有武器库..."

GIT_SSH_COMMAND="ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=accept-new"
# 步骤 7：拉取 GitOps 仓库
if [ ! -d "$HOME/sm-config" ]; then
    git clone git@github.com:${GITHUB_USER}/${GITHUB_REPO}.git "$HOME/sm-config"
else
    cd "$HOME/sm-config"
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    git fetch origin "$current_branch"
    git reset --hard "origin/$current_branch"
fi

# 步骤 8：神圣交接（移交执行权给 Git 仓库内部的核心装配脚本）
echo "[INFO] 引导程序阶段性使命完成，触发 Stage 2..."
chmod +x "$HOME/sm-config/scripts/setup.sh"
"$HOME/sm-config/scripts/setup.sh"
EOF

# 赋予临时脚本执行权限
chmod +x /tmp/xerath-init.sh

# 3. 跨域调用：以 xerath 身份执行该脚本
# 极其重要：不要用后台或管道运行，保持前台执行以维系交互式 TTY
sudo -i -u xerath /tmp/xerath-init.sh

# 4. 阅后即焚，销毁痕迹
rm -f /tmp/xerath-init.sh

echo "=========================================="
echo "🎉 宿主机与用户态装配全链路完成！"
echo "=========================================="
