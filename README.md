# Local-Deploy 使用文档

## 简介

Local-Deploy 是一个基于 Git Hook 的轻量本地 CI/CD 工具。在 `git push` 时自动执行 Maven 打包并部署到远程 Docker 服务器，无需 Jenkins、GitLab Runner 等额外服务。

---

## 环境要求

| 工具 | 用途 |
|------|------|
| Git | Hook 触发机制 |
| Maven | 本地构建 |
| Docker CLI | 远程 Docker 操作（不需要本地 Docker Daemon） |
| Bash | Linux/Mac 自带，Windows 使用 Git 自带的 Bash |

---

## 安装

### 方式一：全局安装（推荐）

```bash
# 克隆项目
git clone <repo-url> ~/local-deploy

# 安装到 /usr/local/bin（需要 sudo）
sudo ~/local-deploy/install.sh

# 或安装到用户目录
~/local-deploy/install.sh ~/.local/bin
```

安装后可在任意目录使用 `local-deploy` 命令。

### 方式二：直接使用

不安装，直接通过脚本路径调用：

```bash
bash /path/to/local-deploy/local-deploy.sh init
bash /path/to/local-deploy/local-deploy.sh deploy
```

---

## 快速开始

### 1. 初始化项目

在你的 Maven 项目根目录（需要是 Git 仓库）执行：

```bash
cd /path/to/your-maven-project
local-deploy init
```

该命令会：
- 生成 `local-deploy.yml` 配置文件
- 安装 `pre-push` Git Hook 到 `.git/hooks/`（自动写入 Local-Deploy 安装路径）
- 检测 Git、Maven、Docker CLI 是否可用

### 2. 编写 Dockerfile

在项目根目录创建以 profile 命名的 Dockerfile，例如 `dev.dockerfile`：

```dockerfile
FROM openjdk:17-jdk-slim
COPY target/*.jar /app/app.jar
ENV JAVA_OPTS=""
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar /app/app.jar"]
```

多环境则创建多个文件：`dev.dockerfile`、`prod.dockerfile` 等。

### 3. 修改配置

编辑 `local-deploy.yml`，根据实际情况修改：

```yaml
# 自动部署开关（设为 false 则 git push 不触发部署）
auto_deploy: true

maven:
  profile: dev
  goals: clean package
  options: -DskipTests

docker:
  cli: docker
  host: tcp://192.168.192.1:2375
  image_tag: latest
  jvm_opts: -Xms256m -Xmx512m
  ports: 8080:8080
  env: SPRING_PROFILES_ACTIVE=dev
  volumes: /data/logs:/app/logs
  network:
  extra_args: --restart=always
```

### 4. 部署

两种触发方式：

```bash
# 方式一：手动触发（完整流水线）
local-deploy deploy

# 方式二：git push 自动触发（通过 pre-push hook，后台执行）
git push

# 查看部署日志
local-deploy log

# 实时跟踪正在进行的部署
local-deploy log --follow

# 仅执行 Maven 构建，跳过 Docker 部署
local-deploy deploy --skip-docker

# 仅执行 Docker 部署，跳过 Maven 构建
local-deploy deploy --skip-maven

# 指定 profile 并跳过 Docker
local-deploy --profile prod --skip-docker
```

---

## 命令参考

### `local-deploy init`

在当前 Git 项目中初始化 Local-Deploy。

```bash
local-deploy init

# 强制覆盖已有的配置文件和 pre-push hook
local-deploy init --force
```

| 参数 | 说明 |
|------|------|
| `--force`, `-f` | 强制覆盖已有的 `local-deploy.yml` 和 `pre-push` hook |

行为：
- 生成 `local-deploy.yml` 配置文件（已存在则跳过，`--force` 强制覆盖）
- 安装 `pre-push` Git Hook 到 `.git/hooks/`（已存在则跳过，`--force` 强制覆盖）
- Hook 中自动写入 Local-Deploy 的安装路径，无需全局安装也能正常执行
- 检测 Git、Maven、Docker CLI 是否可用

### `local-deploy deploy`

手动触发构建部署流程。

```bash
# 使用配置文件中的 profile
local-deploy deploy

# 覆盖 profile（不修改配置文件）
local-deploy deploy --profile prod

# 仅 Maven 构建，跳过 Docker
local-deploy deploy --skip-docker

# 仅 Docker 部署，跳过 Maven
local-deploy deploy --skip-maven
```

参数说明：

| 参数 | 说明 |
|------|------|
| `--profile <name>` | 覆盖配置文件中的 Maven profile |
| `--skip-maven` | 跳过 Maven 构建，仅执行 Docker 构建和部署 |
| `--skip-docker` | 跳过 Docker 构建和部署，仅执行 Maven 构建 |
| `--hook` | 标记为 Git Hook 触发（受 `auto_deploy` 配置控制） |

> 以上参数也可作为顶层参数使用，例如 `local-deploy --skip-docker` 等价于 `local-deploy deploy --skip-docker`。

执行流程：
1. 读取 `local-deploy.yml` 配置
2. 执行 Maven 构建：`mvn {goals} -P{profile} {options}`（可通过 `--skip-maven` 跳过）
3. 连接远程 Docker Daemon
4. 构建 Docker 镜像：`docker build -f {profile}.dockerfile -t {artifactId}-{profile}:{tag} .`
5. 停止并删除同名旧容器
6. 启动新容器（步骤 3-6 可通过 `--skip-docker` 跳过）

### `local-deploy container <action>`

管理已部署的 Docker 容器。容器名称自动从配置推导（`{artifactId}-{profile}`）。

```bash
local-deploy container stop       # 停止容器
local-deploy container start      # 启动已停止的容器
local-deploy container restart    # 重启容器
local-deploy container rm         # 删除容器
local-deploy container logs       # 查看容器日志
local-deploy container logs -f    # 实时追踪日志（Ctrl+C 停止）
local-deploy container status     # 查看容器状态
```

| Action | 说明 |
|--------|------|
| `stop` | 停止运行中的容器 |
| `start` | 启动已停止的容器 |
| `restart` | 重启容器 |
| `rm` | 删除容器（需先停止） |
| `logs` | 查看容器日志，支持 `--follow` 或 `-f` 实时追踪 |
| `status` | 显示容器的运行状态、端口映射等信息 |

### `local-deploy log`

查看最近一次部署的日志输出。日志文件为项目根目录下的 `local-deploy.log`。

```bash
# 查看最近一次部署日志
local-deploy log

# 实时跟踪部署日志（部署进行中时使用，Ctrl+C 停止）
local-deploy log --follow
local-deploy log -f
```

| 参数 | 说明 |
|------|------|
| `--follow`, `-f` | 实时跟踪日志输出（等价于 `tail -f`） |

> 日志文件在 `git push` 触发 hook 时自动生成，每次执行覆盖上一次的日志。

### `local-deploy --help`

显示帮助信息。

### `local-deploy --version`

显示版本号。

---

## 配置详解

### 顶层配置

| 字段 | 说明 | 默认值 | 示例 |
|------|------|--------|------|
| `auto_deploy` | 是否在 git push 时自动触发部署 | `true` | `false` |

### maven 部分

| 字段 | 说明 | 默认值 | 示例 |
|------|------|--------|------|
| `profile` | Maven Profile 名称（**必填**） | — | `dev` |
| `goals` | Maven 构建目标 | `clean package` | `clean package` |
| `options` | 额外 Maven 参数 | （空） | `-DskipTests -U` |

### docker 部分

| 字段 | 说明 | 默认值 | 示例 |
|------|------|--------|------|
| `cli` | Docker CLI 可执行文件路径 | `docker` | `/usr/local/bin/docker` |
| `host` | 远程 Docker Daemon 地址（**必填**） | — | `tcp://192.168.1.100:2375` |
| `image_tag` | 镜像标签 | `latest` | `1.0.0` |
| `jvm_opts` | JVM 参数，注入为 `JAVA_OPTS` 环境变量 | （空） | `-Xms256m -Xmx512m` |
| `ports` | 端口映射，逗号分隔 | （空） | `8080:8080,9090:9090` |
| `env` | 环境变量，逗号分隔 | （空） | `SPRING_PROFILES_ACTIVE=dev,DB_HOST=db` |
| `volumes` | 卷挂载，逗号分隔 | （空） | `/data/logs:/app/logs,/data/config:/app/config` |
| `network` | Docker 网络 | （空） | `my-network` |
| `extra_args` | 额外 `docker run` 参数 | （空） | `--restart=always --memory=512m` |

---

## 自动命名规则

镜像名称和容器名称均自动生成，无需手动配置：

```
{artifactId}-{profile}:{image_tag}
```

- **artifactId**：自动从项目 `pom.xml` 的 `<artifactId>` 标签解析（跳过 `<parent>` 块）
- **profile**：来自 `local-deploy.yml` 中的 `maven.profile`
- **image_tag**：来自 `docker.image_tag`，默认 `latest`

例如 `pom.xml` 中 artifactId 为 `my-service`，profile 为 `dev`，则：
- 镜像：`my-service-dev:latest`
- 容器：`my-service-dev`

---

## 项目文件结构

使用 Local-Deploy 后，你的 Maven 项目中会多出以下文件：

```
your-maven-project/
├── pom.xml
├── src/
├── local-deploy.yml          # Local-Deploy 配置（需纳入版本管理）
├── local-deploy.log          # 部署日志（自动生成，建议加入 .gitignore）
├── dev.dockerfile            # dev 环境 Dockerfile（需纳入版本管理）
├── prod.dockerfile           # prod 环境 Dockerfile（可选）
└── .git/
    └── hooks/
        └── pre-push          # Git Hook（自动安装，不纳入版本管理）
```

Local-Deploy 工具自身的目录结构：

```
Local-Deploy/
├── local-deploy.sh           # 主入口脚本
├── install.sh                # 安装脚本
├── lib/
│   ├── config.sh             # 配置解析模块
│   ├── docker.sh             # Docker 构建部署 & 容器管理模块
│   ├── maven.sh              # Maven 构建模块
│   └── utils.sh              # 工具函数
├── templates/
│   ├── local-deploy.yml      # 配置文件模板
│   └── pre-push              # Git Hook 模板
├── docs/
│   ├── changelog/            # 功能迭代变更记录
│   │   ├── v1.1.0.md
│   │   └── v1.1.1.md
│   └── feature/              # 功能迭代规划
│       ├── v1.1.0.md
│       └── v1.1.1.md
├── README.md                 # 使用文档
└── REQUIREMENTS.md           # 需求文档
```

建议将 `local-deploy.yml` 和 `*.dockerfile` 纳入 Git 版本管理。

---

## 远程 Docker Daemon 配置

Local-Deploy 通过 `DOCKER_HOST` 环境变量连接远程 Docker，需要远程服务器开启 Docker TCP 端口。

在远程服务器上编辑 `/etc/docker/daemon.json`：

```json
{
  "hosts": ["unix:///var/run/docker.sock", "tcp://0.0.0.0:2375"]
}
```

重启 Docker：

```bash
sudo systemctl restart docker
```

> **安全提示**：`tcp://0.0.0.0:2375` 无认证，仅在可信内网使用。生产环境应配置 TLS 认证。

---

## 常见问题

### push 会被阻塞吗？

不会。`pre-push` hook 将部署流程放到后台执行（`nohup ... &`），git push 立即返回。部署日志自动写入项目根目录的 `local-deploy.log`，可通过 `local-deploy log` 查看。

### Windows 能用吗？

能。Windows 安装 Git 后自带 Bash 环境，所有 Shell 脚本均可在 Git Bash 中运行。

### 没有本地 Docker Daemon 能用吗？

能。只需安装 Docker CLI，Local-Deploy 通过 `DOCKER_HOST` 环境变量将所有 Docker 操作指向远程 Daemon，不依赖本地 Daemon。

### 如何部署到不同环境？

为每个环境创建独立的 profile 和 Dockerfile：

```bash
# 部署 dev 环境（使用配置文件默认值）
local-deploy deploy

# 部署 prod 环境（覆盖 profile）
local-deploy deploy --profile prod
```

确保项目根目录存在对应的 `dev.dockerfile` 和 `prod.dockerfile`。

### 配置文件已存在，init 会覆盖吗？

默认不会。`local-deploy init` 检测到 `local-deploy.yml` 或 `pre-push` hook 已存在时会跳过。如需强制覆盖（例如升级到新版 hook），使用：

```bash
local-deploy init --force
```

### 如何临时禁用 git push 自动部署？

在 `local-deploy.yml` 中设置：

```yaml
auto_deploy: false
```

这样 `git push` 时 Hook 会跳过部署，但手动执行 `local-deploy deploy` 不受影响。无需删除或修改 Git Hook。

### 如何查看/管理已部署的容器？

使用 `container` 命令：

```bash
local-deploy container status     # 查看容器状态
local-deploy container logs -f    # 实时查看日志
local-deploy container restart    # 重启容器
local-deploy container stop       # 停止容器
local-deploy container rm         # 删除容器
```
