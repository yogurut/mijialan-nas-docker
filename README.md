# MijiaLAN on UGREEN DX4600 — 单容器产品

把 [iPocket-APP/MijiaLAN](https://github.com/iPocket-APP/MijiaLAN) 的 Rust 分支
（`MijiaLAN-rs`，固定提交 `048d2911ffff8a3223e41f4b8036b6e8554dad96`，版本 0.1.0）
做成一个 Docker 容器，跑在绿联 DX4600（UGOS Pro，x86_64 Intel N5105）上，
只跑无界面 CLI 桥接（`mijia-rust bridge`），把米家 Wi-Fi 设备接进 Apple「家庭」。

> **先说清楚这是什么、不是什么**
>
> - 这不是上游官方镜像：上游没有提供任何运行时镜像 / compose，`main`
>   分支是 macOS 15 专属 Swift 应用，根本进不了 Linux 容器；`MijiaLAN-rs`
>   分支自带的 `scripts/docker/Dockerfile` 也只是**构建容器**，不是运行容器。
>   本包就是把“构建 + 运行 + 凭据服务”拼成一个能用的产品。
> - 容器里**没有桌面界面**：NAS 没有 X11/Wayland，GPUI 桌面版不在镜像里。
>   取而代之的是一个**网页界面**（见下）：登录扫码、HomeKit 配对码、
>   设备列表都在浏览器里完成，不用在终端里看字符画二维码。
>   日常控制走 iPhone「家庭」/ Siri。

## 网页界面（登录 / 配对都在这里）

容器启动后，浏览器打开 **http://&lt;NAS 局域网 IP&gt;:8080**，页面分三块：

1. **扫码登录米家**：点“开始扫码登录”，页面上出现一个可扫的二维码，
   用米家 App 扫码并确认，设备就导入了。登录时会先暂停桥接，导入
   完成自动恢复。终端版 `./scripts/login.sh` 只是备用。
2. **HomeKit 配对**：页面显示桥的配对码和配对二维码，iPhone「家庭」
   里扫码或手动输码即可。
3. **设备 / 日志**：已导入的设备列表、广播发现、重启桥接、桥接日志。

页面是 Python 标准库写的（`webui/app.py`，无第三方依赖），
二维码是把 CLI 打印的 Dense1x2 字符画逐像素还原成 SVG 的，
已用测试桩验证过：还原出的 430 个黑格与原始二维码矩阵完全一致。

**只限局域网**：页面没有账号密码，不要把 8080 端口映射到公网。
> - 上游 Rust 版是 0.1.0 前期版本。Linux 下干净容器安装、CLI 运行和
>   33 项核心 / HomeKit 测试已通过，但 **Linux 上 iPhone 实机配对尚未经
>   上游验收**，本包在 DX4600 上的完整配对流程也未经实机验证——按下面
>   步骤走，走到配对那一步如果 iPhone 找不到桥，先看「排错」一节，
>   不要默认一定能成。

## 它是怎么工作的

```
米家设备 (UDP 54321, miIO/MIoT) ──局域网──> DX4600 容器 (host 网络)
                                          ├─ mijia-rust bridge (常驻)
                                          ├─ HomeKit 桥 (mDNS 广播, 随机持久化 TCP 端口)
                                          └─ /data 持久化
iPhone「家庭」/ HomePod / Siri ──────────> 桥 (配对码, 未认证配件, 点确认继续)
```

持久化全部在 `./data`（NAS 上一个文件夹，容器里挂为 `/data`）：

| 路径 | 内容 |
|---|---|
| `data/config/MijiaLAN Rust/devices.json` | 设备清单（不含 token） |
| `data/config/MijiaLAN Rust/credentials.enc` | 加密后的 token、HomeKit 身份与配对信息 |
| `data/local/share/keyrings/` | gnome-keyring：32 字节主密钥 |

主密钥存在 Secret Service（gnome-keyring）里，容器启动时由
`entrypoint.sh` 用 `.env` 里的 `MIJIALAN_KEYRING_PASSWORD` 解锁。
程序**不会**降级成明文保存凭据，钥匙串不可用或密码不对时，
会直接报“系统凭据存储不可用”并拒绝保存——这是上游设计，不是 bug。

## 准备工作

1. DX4600 已装好 UGOS Pro 自带的 Docker 应用，NAS 和米家设备在**同一局域网**。
2. NAS 上开启 SSH：控制面板 → 系统设置 → 开发者模式（UGOS 默认 SSH 端口 922，root 登录）。
3. 有一台 iPhone，已登录要用的 Apple ID；远程控制 / 自动化还需要
   HomePod 或 Apple TV 做家居中枢（和官方 README 说的一致）。

## 部署步骤（SSH 到 NAS 上操作）

### 1. 把本包传到 NAS

```bash
# 例如放在 Docker 共享目录下，路径按你自己的存储池调整
mkdir -p /volume1/docker/mijialan
# 把 Dockerfile、docker-compose.yml、.env.example、entrypoint.sh、scripts/
# 拷到 /volume1/docker/mijialan/（文件传输 / SMB / scp 都行）
cd /volume1/docker/mijialan
```

### 2. 设置钥匙串密码（只设一次，之后永远别改）

```bash
cp .env.example .env
vi .env   # 把 MIJIALAN_KEYRING_PASSWORD 改成一个长随机密码，记进密码管理器
```

这个密码**不是**小米账号密码，只是用来解锁容器内 gnome-keyring 的。
改掉它 = 主密钥解不开 = 所有设备要重新导入、HomeKit 要重新配对。
`.env` 不要发给任何人、不要提交到任何仓库。

### 3. 拉取镜像（不用在 NAS 上构建）

```bash
docker compose pull
```

镜像由 GitHub Actions 编好、发布在 `ghcr.io/yogurut/mijialan-nas:latest`
（公开，不用登录）。想固定版本就把 compose 里的 `image:` 改成
`ghcr.io/yogurut/mijialan-nas:354fabc`。

### 4. 启动（桥接 + 网页界面一起跑）

```bash
docker compose up -d
```

### 5. 在网页上扫码导入设备（推荐）

浏览器打开 **http://&lt;NAS 局域网 IP&gt;:8080**：

1. 在“扫码登录米家”里点**开始扫码登录**，页面出现二维码，
   用**米家 App 扫码并确认**，导入完成后页面显示“导入 N 台设备”。
   地区默认 `cn`，账号在其他区就改 `.env` 里的 `MIJIALAN_REGION`
   （cn / de / us / sg / ru / i2）。
2. 已知 IP + token 的设备也可以逐台手动加（备用）：
   ```bash
   ./scripts/add-device.sh 192.168.31.20 "书桌台灯"
   # token 在提示出现时输入，不回显，也不会进 shell 历史
   ```
3. 在页面“设备”一栏核对导入结果；也可以点“广播发现新设备”
   （3 秒广播发现局域网设备）。

### 6. iPhone「家庭」里添加

在同一个网页的“HomeKit 配对”一栏里看配对码和配对二维码：

1. iPhone 打开「家庭」→ 右上角 `+` → **添加配件**。
2. 扫网页上的二维码，或选“没有二维码”，手动输入配对码。
3. 提示**未认证配件**是正常的（社区项目，没有 HomeKit / MFi 认证），点确认继续。
4. 按提示把桥接的设备分到房间。已经原生支持 HomeKit 的设备
   建议不要重复桥接，会出现两个同名配件。

配对成功后，桥的配对信息存在 `credentials.enc` 里，
容器重建、NAS 重启后不需要重新配对（只要 `./data` 还在）。
桥的 TCP 端口是首次启动随机选定、之后持久化在加密凭据里的，
重启容器不会变；容器用 `network_mode: host`，直接用 NAS 的局域网地址，
不需要在 compose 里映射端口。

## 日常使用

```bash
docker compose logs -f mijialan   # 看桥的日志 / 配对码
./scripts/status.sh               # 容器状态 + 日志 + 设备清单
docker compose restart mijialan   # 重启桥
docker compose down               # 停掉（数据在 ./data 里，不会丢）

# 控制一台设备（教学式检查用，日常还是走「家庭」）
docker compose run --rm mijialan set <did> 2.1 true
# did 从 list 的输出里找；2.1 是属性 siid.aiid，不同型号不一样
```

**备份**：定期备份整个 `./data` 文件夹。丢了它 = 重新导入 + 重新配对；
只备份 `devices.json` 是不够的，token 和配对信息都在 `credentials.enc`
和钥匙串文件里。

## 排错

| 现象 | 先查什么 |
|---|---|
| 容器起不来，报 `MIJIALAN_KEYRING_PASSWORD is not set` | `.env` 没建或没填密码；`docker compose` 要在项目目录下运行才能读到 `.env` |
| 报“系统凭据存储不可用 / 无法访问系统凭据存储” | 钥匙串没解锁：看启动日志里 `entrypoint.sh` 有没有报错；确认 `.env` 密码和首次导入时**同一个**；删掉 `./data` 重来之前先确认密码记对了 |
| `login` 扫码后一直等不到确认 | 米家 App 和 NAS 在同一局域网；扫码导入要联网（小米云 + miot-spec.org）；换个网络重试 |
| 设备显示离线 | 路由器重新分配 IP 会自动找回，等一轮询；设备重新配网后 token 可能变了，要重新导入；固件没开放局域网接口的设备控制不了 |
| iPhone 找不到桥 | 必须同一局域网；容器必须是 host 网络（本包已是）；NAS 防火墙 / 路由器 AP 隔离要放行 mDNS（UDP 5353 多播）和桥的 TCP 端口；重启一次容器再扫 |
| 配对码输了提示不对 | 配对码只在**首次未配对**时打印；已配对过的桥不会再显示，`docker compose logs` 里找最早那次启动的日志，或者删 `./data` 重新导入 + 重新配对（最后手段） |
| 想换一台设备进 / 出「家庭」 | 目前 CLI 没有逐台开关桥接的命令；先用 `remove <did>` 移除再重新 `add`，或等上游桌面版 |

## 限制（实话）

- 只支持 Wi-Fi 的 miIO / MIoT 设备。**不支持**蓝牙设备、Zigbee /
  蓝牙 Mesh 网关子设备、云端灯组。
- 内置完整适配的只有 10 个型号（插座、净化器、台灯、空调伴侣、
  循环扇、料理机、养生壶、空气炸锅、电饭煲各 1–2 款），其他型号
  靠 miot-spec.org 的规格生成通用控件，未必每个固件都接受局域网写入。
- 扫地机只显示为一个开关（开=清扫，关=回充），房间 / 分区等
  带厂商参数的动作不开放。
- 构建产物是 Debug 还是 Release：本包用 `--release` 编译 CLI，
  上游当前验证过的 Linux 包是 Debug 测试包，Release 在 Linux
  上的表现以你实机为准。
- 镜像里没有 GUI，`mijialan-rust` 桌面版、`--demo` 演示模式都不在
  本包的运行范围内。

## 文件清单

| 文件 | 用途 |
|---|---|
| `Dockerfile` | 多阶段构建：builder 编 CLI，runtime 只留运行依赖 + 钥匙串 + Python |
| `entrypoint.sh` | 启动 D-Bus 会话、解锁 gnome-keyring、后台起桥接、前台跑网页界面 |
| `webui/app.py` + `webui/index.html` | 网页界面（标准库 Python，无第三方依赖）：登录二维码、配对码、设备、日志 |
| `scripts/bridgectl.sh` | 桥接启停管理（网页界面调用），日志写 `/data/bridge.log` |
| `docker-compose.yml` | 单容器编排：host 网络、挂载 `./data`、拉 ghcr 镜像 |
| `.env.example` | 复制成 `.env` 后填钥匙串密码和地区 |
| `scripts/login.sh` | 首次扫码导入（终端备用，首选网页） |
| `scripts/add-device.sh` | 手动按 IP + token 加设备 |
| `scripts/status.sh` | 状态 + 日志 + 设备清单 |
