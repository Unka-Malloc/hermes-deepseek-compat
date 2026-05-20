# Hermes DeepSeek Compatibility Patch

这是一个面向 Hermes Agent 的通用 DeepSeek V4 Pro 兼容补丁包，包含代码补丁、最小配置校验和自动化应用脚本。

它不绑定具体机器、VM、部署目录或聊天平台。默认路径遵循 Hermes 常见安装布局，也可以通过环境变量覆盖。

## 使用方式

在运行 Hermes 的环境中执行：

```bash
git clone https://github.com/Unka-Malloc/hermes-deepseek-compat.git
cd hermes-deepseek-compat
./apply-hermes-deepseek-compat.sh
```

默认路径：

```bash
HERMES_HOME="$HOME/.hermes"
HERMES_REPO="$HERMES_HOME/hermes-agent"
CONFIG_FILE="$HERMES_HOME/config.yaml"
```

脚本会自动检查并修正：

- Hermes 代码补丁是否已应用。
- DeepSeek provider 的兼容参数是否正确。
- Hermes 默认模型是否配置为 DeepSeek V4 Pro。
- DeepSeek V4 Pro 所需的最小 reasoning / tool-use 配置是否存在。

默认还会运行定向测试。如果当前环境存在 `hermes-gateway` systemd 服务，脚本会重启该服务；否则会自动跳过。

## 常用参数

```bash
./apply-hermes-deepseek-compat.sh --check-only
./apply-hermes-deepseek-compat.sh --skip-tests
./apply-hermes-deepseek-compat.sh --no-restart
./apply-hermes-deepseek-compat.sh --skip-smoke
```

可通过环境变量覆盖路径：

```bash
HERMES_HOME=/path/to/hermes-home \
HERMES_REPO=/path/to/hermes-agent \
./apply-hermes-deepseek-compat.sh
```

## 文件

- `patches/deepseek-v4-thinking-compat.patch`: Hermes Agent 代码补丁和回归测试。
- `apply-hermes-deepseek-compat.sh`: 幂等入口脚本。

## 许可

本仓库使用 MIT License。补丁目标项目 `hermes-agent` 也是 MIT License。
