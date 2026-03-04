# Local-Deploy 需求规格文档

## 一、项目概述

### 1.1 背景

Git 远程仓库无法安装 CI/CD 功能（如 GitLab Runner、GitHub Actions 等），需要一个轻量的本地工具，在 `git push` 时自动完成 Maven 打包和远程 Docker 部署，替代传统 CI/CD 平台。

### 1.2 项目定位

一个**基于 Git Hook 的轻量本地 CI/CD 工具**，零服务端依赖，通过 Shell 脚本实现，适配不同 Maven 项目，通过 YAML 配置文件参数化控制。

### 1.3 现有方案对比

| 现有方案 | 差距 |
|---------|------|
| Jenkins | 需要独立 Java 服务，过于重量级 |
| GitLab CI/CD | 依赖 GitLab Runner，远程仓库不支持 |
| Drone CI | 需要独立服务 + Git 平台 Webhook |
| git-build-hook-maven-plugin | 仅管理 Hook 安装，无 Docker 构建部署 |
| 手写 post-commit 脚本 | 无参数化配置、无多项目适配 |

**结论：市面上无完全匹配的轻量方案，本项目填补此空白。**

---

## 二、核心流程

```
git push → pre-push hook 触发 → 读取 YAML 配置 → Maven 本地打包 → Docker 远程构建镜像 → 停止旧容器 → 启动新容器
```

**关键约束：构建/部署结果不阻塞 git push，始终允许推送，仅输出日志。**

---

## 三、功能清单

### F1：项目初始化（`local-deploy init`）

- 在目标 Git 仓库根目录生成 `local-deploy.yml` 配置模板
- 自动安装 `pre-push` Git Hook 到 `.git/hooks/`
- 检测当前环境（Maven、Docker CLI 可用性）并提示

### F2：Maven 本地构建

- 读取配置中的 Maven profile 执行构建
- 支持自定义构建目标（goals），默认 `clean package`
- 支持额外 Maven 参数（如 `-DskipTests`）
- 构建命令：`mvn {goals} -P{profile} {options}`

### F3：Docker 远程镜像构建

- 通过 `DOCKER_HOST="tcp://{host}:{port}"` 连接远程 Docker Daemon
- 根据 Maven profile 选择对应的 `{profile}.dockerfile` 文件
- 将本地构建上下文发送到远程 Daemon 构建镜像
- 镜像名称自动生成：`{artifactId}-{profile}`（artifactId 从 pom.xml 解析）
- 兼容两种本地环境：
  - 安装了完整 Docker 环境（有本地 daemon）
  - 仅安装 Docker CLI（无本地 daemon）
  - 两者均通过 `DOCKER_HOST` 环境变量指向远程 Daemon 工作

### F4：Docker 远程容器部署

- 使用 `docker run` 启动容器
- 容器名称自动生成：`{artifactId}-{profile}`（与镜像名称一致）
- 自动替换：检测同名旧容器 → 停止 → 删除 → 启动新容器
- 支持配置：端口映射、环境变量、卷挂载、网络、JVM 参数、额外 docker run 参数
- JVM 参数通过 `JAVA_OPTS` 环境变量注入容器

### F5：手动 CLI 触发

- 支持 `local-deploy deploy` 手动触发完整构建部署流程（不依赖 git push）
- 支持 `--profile` 参数覆盖配置文件中的 profile
- 与 Hook 触发执行完全相同的逻辑

### F6：统一 YAML 配置

- 配置文件 `local-deploy.yml` 放置在项目根目录
- 使用纯 Shell 解析（awk），零外部依赖
- 持久化存储，每个项目独立配置

---

## 四、不包含的功能

- 日志持久化 / 历史记录
- 多服务器部署
- Docker Compose 编排
- 构建通知（邮件 / 钉钉等）
- Web 管理界面
- 镜像仓库推送（Harbor / Docker Hub）
- 回滚功能

---

## 五、配置文件设计

### 5.1 配置文件

`local-deploy.yml`，位于目标项目根目录，限两级嵌套以便 Shell 解析。

```yaml
# Maven 构建配置
maven:
  profile: dev                          # Maven Profile 名称
  goals: clean package                  # Maven 构建目标
  options: -DskipTests                  # 额外 Maven 参数

# Docker 部署配置
docker:
  cli: docker                           # Docker CLI 路径（如 /usr/local/bin/docker）
  host: tcp://192.168.192.1:2375        # 远程 Docker Daemon 地址
  image_tag: latest                     # 镜像标签
  jvm_opts: -Xms256m -Xmx512m          # JVM 参数（通过 JAVA_OPTS 注入）
  ports: 8080:8080,9090:9090            # 端口映射（逗号分隔）
  env: SPRING_PROFILES_ACTIVE=dev       # 环境变量（逗号分隔）
  volumes: /data/logs:/app/logs         # 卷挂载（逗号分隔）
  network: my-network                   # Docker 网络（可选）
  extra_args: --restart=always          # 额外 docker run 参数
```

### 5.2 Dockerfile 约定

- 文件命名：`{profile}.dockerfile`（如 `dev.dockerfile`、`prod.dockerfile`）
- 存放位置：项目根目录
- 示例：

```dockerfile
FROM openjdk:17-jdk-slim
COPY target/*.jar /app/app.jar
ENV JAVA_OPTS=""
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar /app/app.jar"]
```

### 5.3 命名规则

| 项目 | 规则 | 示例 |
|------|------|------|
| 镜像名称 | `{artifactId}-{profile}` | `my-service-dev` |
| 容器名称 | `{artifactId}-{profile}` | `my-service-dev` |
| artifactId | 自动从 `pom.xml` 解析 | — |
| profile | 从 `local-deploy.yml` 读取 | — |

---

## 六、技术方案

### 6.1 技术选型

| 项 | 选择 |
|----|------|
| 实现语言 | Shell 脚本（跨平台，Windows 通过 Git 自带 Bash 运行） |
| 触发机制 | Git pre-push Hook |
| 配置格式 | YAML（纯 Shell/awk 解析，限两级嵌套） |
| Docker 远程 | `DOCKER_HOST=tcp://` 环境变量 |
| 构建工具 | Maven（本地执行） |

### 6.2 项目文件结构

```
Local-Deploy/
├── local-deploy.sh               # 主脚本入口
├── install.sh                    # 安装脚本（将工具添加到 PATH）
├── lib/
│   ├── config.sh                 # YAML 配置解析模块
│   ├── maven.sh                  # Maven 构建模块
│   ├── docker.sh                 # Docker 构建部署模块
│   └── utils.sh                  # 工具函数（日志、颜色输出、环境检测）
└── templates/
    ├── local-deploy.yml          # YAML 配置模板
    └── pre-push                  # Git Hook 模板脚本
```

---

## 七、运行环境要求

| 依赖 | 说明 |
|------|------|
| Git | 用于 Hook 机制；Windows 通过 Git 自带的 Bash 运行脚本 |
| Maven | 本地执行构建 |
| Docker CLI | 用于远程 Docker 操作（无需本地 Docker Daemon） |
| Bash | Linux/Mac 自带；Windows 通过 Git 自带 |

---

## 八、验证方案

1. **初始化验证**：在 Maven 项目中执行 `local-deploy init`，检查配置文件和 Hook 正确生成
2. **配置解析验证**：修改 `local-deploy.yml`，验证各参数正确解析
3. **Maven 构建验证**：执行 `local-deploy deploy`，验证打包按配置执行
4. **Docker 部署验证**：确认远程 Docker 上镜像构建成功、旧容器被替换、新容器正常运行
5. **Hook 触发验证**：执行 `git push`，验证 pre-push Hook 自动触发完整流程
6. **失败不阻塞验证**：Maven 构建失败时，确认 git push 仍然成功
