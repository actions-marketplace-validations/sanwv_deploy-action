# Deploy Action

[English](README.md) | [简体中文](README.zh-CN.md)

通过 SSH 将已构建的静态文件发布到 Linux 服务器。Action 使用 `rsync` 上传每个版本，并在新版本准备完成后原子切换 `current` 符号链接。

本 Action 发布于 [`sanwv/deploy-action`](https://github.com/sanwv/deploy-action)。

## 功能

- 使用 `current`、`releases/` 和 `shared/` 目录管理版本。
- 通过切换 `current` 符号链接原子激活新版本。
- 可配置旧版本保留数量，便于回滚。
- 支持持久化 shared 文件和目录，并可选择初始化或同步文件。
- 可为每个 shared 项配置权限。
- 使用 Bash、SSH 和 rsync；不依赖 Ansible，也不负责构建应用。

## 工作方式

`target` 是远端部署根目录，Action 会管理以下目录结构：

```text
/srv/www/my-site/
├── current -> releases/<release-id>
├── releases/
│   ├── <release-id>/
│   └── ...
└── shared/
```

每次运行都会将 `source` 上传到新的 release 目录。准备完成后，Action 原子更新 `current`，并根据 `releases_to_keep` 清理旧版本。Web 服务器的网站根目录应指向 `target/current`。

增量发布时，Action 在 `target/shared/.shared-copy/` 保存最近一次同步的完整项目副本。rsync 以此副本为目标，校验文件内容并只传输差异；传输成功后，在同一 rsync 接收进程持有远端 `flock` 锁期间，将副本复制到新的 release。release 文件彼此独立，不共享硬链接，因此直接调试或修改旧 release 不会改动新版本。首次部署没有副本，会完整上传。`.shared-copy` 是 Action 保留的路径，不能在 `shared_items` 中声明；它会占用约一份项目大小的磁盘空间。激活和清理也通过远端 `flock` 串行处理。

切换符号链接前发生错误时，`current` 仍指向上一个版本。为保证原子切换，`target/current` 和 `target/releases` 必须位于同一个文件系统。

## 快速开始

在仓库的 **Settings → Secrets and variables → Actions** 中添加以下配置：

| 名称 | 类型 | 说明 |
|---|---|---|
| `SSH_PRIVATE_KEY` | Secret | 可登录部署服务器的 SSH 私钥。 |
| `SSH_KNOWN_HOSTS` | 可选 Secret 或 Variable | 经过核验的服务器 host key，格式与 `known_hosts` 文件一致。不配置时，SSH 使用 `accept-new` 并将首次连接的 host key 保存到 Runner 用户的 known_hosts。 |
| `REMOTE_HOST` | Variable | 服务器主机名或 IP 地址。 |
| `REMOTE_USER` | Variable | SSH 登录用户。 |
| `REMOTE_PORT` | 可选 Variable | SSH 端口，默认 `22`。 |

配置该项时，请通过可信渠道核验服务器 host key，Action 会要求精确匹配。不配置时，SSH 会接受并保存首次遇到的 host key；如果 known_hosts 中已有该主机但 key 发生变化，连接仍会失败。

创建 `.github/workflows/deploy.yml`：

```yaml
name: Deploy static site

on:
  push:
    branches: [main]

concurrency:
  group: production-deploy
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build site
        run: |
          npm ci
          npm run build

      - name: Deploy
        uses: sanwv/deploy-action@v1
        with:
          ssh_private_key: ${{ secrets.SSH_PRIVATE_KEY }}
          # 可选：省略时 SSH 使用 StrictHostKeyChecking=accept-new。
          ssh_known_hosts: ${{ secrets.SSH_KNOWN_HOSTS }}
          remote_host: ${{ vars.REMOTE_HOST }}
          remote_user: ${{ vars.REMOTE_USER }}
          remote_port: ${{ vars.REMOTE_PORT }}
          source: ./dist
          target: /srv/www/my-site
          releases_to_keep: 5
```

`source` 是 Runner 上的目录，相对路径以 `GITHUB_WORKSPACE` 为基准。目录内容会复制到 release 根目录。例如，`./dist/index.html` 会成为 `current/index.html`。

`target` 是部署根目录，不是 `current` 目录。SSH 用户必须能够在该目录下创建目录和符号链接、设置权限及删除旧版本。

## Shared 持久化文件和目录

对于需要跨版本保留的数据，例如用户上传内容或运行时配置，可以使用 `shared_items`。该输入是多行字符串，每行声明一个项目，字段使用逗号分隔的 `key=value` 格式：

```yaml
      - name: Deploy
        uses: sanwv/deploy-action@v1
        with:
          # 为简洁起见，省略其他必填参数。
          shared_items: |
            type=directory,path=uploads,mode=775
            type=file,path=config/runtime.json,mode=664,from=config/runtime.example.json,sync=if-missing
            type=file,path=assets/managed-manifest.json,mode=644,from=shared-seed/manifest.json,sync=always
            type=file,path=data/runtime.json,sync=never
```

| 字段 | 必需 | 适用类型 | 说明 |
|---|---:|---|---|
| `type` | 是 | 目录和文件 | `directory` 或 `file`。 |
| `path` | 是 | 目录和文件 | 相对于远端 `target/shared/` 的路径。 |
| `mode` | 否 | 目录和文件 | 八进制权限，例如目录 `775`、文件 `664`。 |
| `from` | 按需 | 文件 | 相对于项目根目录（`GITHUB_WORKSPACE`）的来源文件路径。 |
| `sync` | 否 | 文件 | `never`、`if-missing` 或 `always`，默认 `never`。 |

### Shared 目录

```text
type=directory,path=uploads,mode=775
```

Action 会创建 `target/shared/uploads`，并将每个 release 中的 `uploads` 替换为指向它的符号链接。目录内容会跨发布保留，不会从构建产物同步。

### 首次初始化 shared 文件

```text
type=file,path=config/runtime.json,mode=664,from=config/runtime.example.json,sync=if-missing
```

Action 会创建 `target/shared/` 下所需的父目录。如果 `target/shared/config/runtime.json` 不存在，就从 `GITHUB_WORKSPACE/config/runtime.example.json` 初始化；如果文件已存在，则保留服务器上的版本。每个 release 的 `config/runtime.json` 都会链接到该 shared 文件。

shared 项中的 `from` 路径相对于**项目根目录（`GITHUB_WORKSPACE`）**，与顶层 `source`（待发布的构建目录）无关。例如，顶层设置 `source: ./dist` 时，`from: config/runtime.example.json` 指的是仓库根目录下的 `./config/runtime.example.json`。

Action 不会创建空的 shared 文件。如果省略 `from` 或使用 `sync=never`，请在服务器上预先创建文件，或由应用/初始化流程创建。

### 每次发布时同步 shared 文件

```text
type=file,path=assets/managed-manifest.json,mode=644,from=shared-seed/manifest.json,sync=always
```

每次发布都会用 `GITHUB_WORKSPACE/shared-seed/manifest.json` 更新 shared 文件。Action 先上传到临时文件，再原子替换目标文件。

`always` 会更新所有 release 共用的文件。即使发布在切换 `current` 前失败，shared 文件也可能已经更新。因此该模式只适用于由仓库管理且允许跨版本更新的数据。需要与特定代码版本严格绑定的配置应放在该 release 内，而不是 shared。

### Shared 配置规则

- `path` 相对于 `target/shared/`，不能以 `/` 开头或包含 `..` 路径分量。
- `from` 相对于 `GITHUB_WORKSPACE`，不能越出项目根目录。
- 目录项不支持 `from` 或 `sync`。
- 文件使用 `if-missing` 或 `always` 时必须设置 `from`。
- 字段值不能包含逗号或等号；每行只配置一个项目。
- `mode` 只接受 3 位或 4 位八进制值。
- Action 使用 `chmod` 设置权限。属主和属组需在服务器上预先配置；Action 不执行 `chown`。

## 输入参数

| 输入 | 必需 | 默认值 | 说明 |
|---|---:|---:|---|
| `ssh_private_key` | 是 | — | SSH 私钥，请通过 GitHub Secret 传入。 |
| `ssh_known_hosts` | 否 | 空 | 经过核验的 SSH host key；留空时使用 `accept-new` 接受并记录新 host key。 |
| `remote_host` | 是 | — | 远端主机名或 IP 地址。 |
| `remote_user` | 是 | — | SSH 登录用户。 |
| `source` | 是 | — | Runner 上已构建文件目录。 |
| `target` | 是 | — | 远端部署根目录。 |
| `remote_port` | 否 | `22` | SSH 端口。 |
| `releases_to_keep` | 否 | `5` | 发布后保留的 release 数量，允许 `1` 到 `100`；活动版本始终保留。 |
| `shared_items` | 否 | 空 | shared 路径、权限和文件同步配置。 |
| `script_before` | 否 | 空 | 在远端创建新 release 前执行的 Bash 脚本。 |
| `script_before_activate` | 否 | 空 | 在远端新 release 准备完成、切换 `current` 前执行的 Bash 脚本。 |
| `script_after` | 否 | 空 | 在远端切换 `current` 后、清理旧 release 前执行的 Bash 脚本。失败时恢复之前的 `current`。 |

### 远端部署脚本

三个脚本输入都在部署服务器上以 Bash 执行，脚本内容按多行文本传入。脚本运行时可使用以下环境变量：

| 变量 | 含义 |
|---|---|
| `DEPLOY_TARGET` | 部署根目录。 |
| `DEPLOY_RELEASE_ID` | 本次 release ID。 |
| `DEPLOY_RELEASE_PATH` | 本次 release 的绝对路径。 |
| `DEPLOY_PREVIOUS_RELEASE` | 部署前 `current` 指向的 release；首次部署为空。 |
| `DEPLOY_HOOK` | 当前钩子阶段：`before`、`before-activate` 或 `after`。 |

`script_before` 在远端基础目录准备后、创建 release 前运行，适合检查磁盘空间、权限或服务状态。`script_before_activate` 在代码同步、shared 链接准备完成后运行，当前工作目录是候选 release，可用于校验候选文件或执行激活前命令。任一脚本返回非零都会中止部署，旧版本继续服务。

`script_after` 在切换 `current` 后运行，当前工作目录是新 release；成功后才清理旧 release。若脚本失败，Action 会在发布锁内将 `current` 原子恢复到 `DEPLOY_PREVIOUS_RELEASE`，保留旧版本并让部署失败。首次部署时若脚本失败，则移除新建的 `current` 链接。应用数据库等外部状态不随代码回滚，相关操作应自行保证兼容性。

构建、runner 本地测试和公网健康检查不属于这些远端钩子，可写在 workflow 的前后 `run:` steps 中。后续本地健康检查失败不会自动触发 Action 回滚。

## 环境要求

- 可通过 SSH 访问的 Linux 服务器。
- 服务器安装 `bash`、`rsync`、`flock` 和常见 GNU/Linux 工具。
- Runner 安装 Bash、OpenSSH 和 rsync。缺少必要命令时 Action 会报告错误。
- SSH 用户对 `target` 有足够权限。Action 不使用 `sudo`。
- Web 服务器的网站根目录配置为 `target/current`。

## 故障排查

**SSH host key 校验失败**

确认 `SSH_KNOWN_HOSTS` 中的主机名、端口和 host key 与当前连接一致，并通过可信渠道核验 host key。

**rsync 或权限错误**

确认 Runner 和服务器都安装了 rsync，并确认 `REMOTE_USER` 可以写入 `TARGET`。Action 不使用 `sudo`。

**应用找不到 shared 文件**

`sync=never` 不会创建文件本身。请确认 shared 文件已存在，或配置相对于 `GITHUB_WORKSPACE` 的 `from`，并选择 `if-missing` 或 `always`。

**网站仍显示旧版本**

确认 Web 服务器的网站根目录指向 `TARGET/current`，而不是固定的 `releases/<release-id>` 目录。
