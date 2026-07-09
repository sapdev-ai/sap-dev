# sap-dev — SIer 开发者手册

**从一台干净的 Windows 笔记本，到部署完成、通过 ATC 检查的 ABAP —— 全程使用 Claude Code 技能。**

> 读者对象：在系统集成商（SIer）工作的 ABAP 开发者/顾问，加入某个客户项目后，希望使用
> **sap-dev** 插件更快地生成和部署自定义代码，同时又不放弃对传输请求、质量门禁
> 或生产系统的控制权。
>
> 阅读时长：约 30 分钟。动手完成首次运行：约 1 小时（其中大部分是一次性的初始设置）。

> 📖 这是英文手册 [`manual.md`](manual.md) 的简体中文译本。**以英文版为准**。如有出入，以英文版为准。

---

## 目录

0. [这个工具集是什么（不是什么）](#0-这个工具集是什么不是什么)
1. [端到端全景图](#1-端到端全景图)
2. [前提条件 —— 你的工作站和你的 SAP 用户](#2-前提条件)
3. [安装插件](#3-安装插件)
4. [首次设置（每台机器 / 每个系统一次）](#4-首次设置)
5. [告诉生成器你的项目情况 —— 客户简介（Customer Brief）](#5-客户简介customer-brief)
6. [从设计文档生成 ABAP](#6-从设计文档生成-abap)
7. [部署代码](#7-部署代码)
8. [质量门禁 —— ATC 和 ABAP Unit](#8-质量门禁)
9. [传输就绪检查、释放与 STMS](#9-传输就绪检查释放与-stms)
10. [一个完整的实战示例 —— 以及 `abap-developer` 代理](#10-一个完整的实战示例)
11. [Day-2 技能：诊断、修复、解释、迁移](#11-day-2-技能)
12. [工具集如何保障你的安全](#12-安全模型)
13. [疑难排查与常见问题](#13-疑难排查与常见问题)
14. [附录 A —— 完整技能目录](#附录-a--完整技能目录)
15. [附录 B —— 设置参考](#附录-b--设置参考)
16. [附录 C —— ABAP 命名与长度限制](#附录-c--abap-命名与长度限制)

---

## 0. 这个工具集是什么（不是什么）

**sap-dev** 是一组四个 Claude Code *插件* —— 它们打包了一系列"技能"（`/sap-…`
斜杠命令），通过 SAP 已经自带的两个标准接口，**用你自己的对话用户驱动一个真实的 SAP
系统**：

- **SAP GUI Scripting**（用 VBScript 驱动 SAP GUI for Windows）—— 用于一切属于
  事务码的操作：SE38、SE37、SE24、SE11、SE91、SE01、ATC……
- **RFC**，通过 SAP .NET Connector（NCo 3.1）—— 用于只读检查和快速通道
  （表读取、FM 签名、传输状态、激活验证）。

| 插件 | 技能 | 它为你提供什么 |
|---|---|---|
| **sap-dev-core** | 50 个 + `abap-developer` 代理 | 登录与连接库、传输处理、ABAP 工作台（SE38/SE37/SE24/SE11/SE91/SE16N/SE01/…）、ATC 质量门禁、ABAP-Unit 运行器、激活、诊断（ST22/SM13/SM12/SLG1/SM37）、交付保障，以及向 QAS/PRD 的 **STMS** 导入。 |
| **sap-gen-code** | 8 个 | **规格 → ABAP** 流水线：读取设计文档（Excel/Word/PDF）、校验它、生成贴合你项目的 ABAP，并将结果与实时系统对照校验。 |
| **sap-migrate** | 8 个 + `cc-migration-engineer` 代理 | 以受跟踪的"战役"（campaign）形式进行的 S/4HANA 自定义代码迁移。 |
| **sap-tcd** | 3 个 | 业务事务自动化：BP、MM01/02/03、VA01/02/03。 |

### 它**不是**什么

- 它**不是**一个会悄悄改写你客户生产系统的机器人。
  每一个不可逆操作（部署、释放、**生产导入**）都受门禁约束，会**先征求你的同意**。
  参见 [§12](#12-安全模型)。
- 它**不会**对 SAP 标准表写 SQL —— 只通过 SAP 自己的写入 API
  （`BAPI_*`、`RPY_*`、`DDIF_*`……）。读取则始终允许。
- 它在**你的** SAP 许可证下、用**你的**授权运行。如果你无法在 SE21 里手工创建一个
  包，技能同样做不到。

> ⚠️ **始终从沙箱 / DEV 客户端开始。** 正如项目自身的许可证说明所述：
> "对生产系统使用本工具风险自负；务必先针对沙箱或开发客户端测试。"

---

## 1. 端到端全景图

对于一个新的自定义报表或接口，"理想路径"是这样的：

```
                        ┌─────────────────────────────────────────────┐
   ONE-TIME SETUP       │  install plugins → /sap-login → /sap-dev-init │
                        └─────────────────────────────────────────────┘
                                            │
        design doc (.xlsx/.docx/.pdf)       ▼
   ┌───────────────────────────────────────────────────────────────────┐
   │  GENERATE                                                          │
   │  /sap-docs-extract → (/sap-docs-convert) → /sap-docs-check         │
   │        → /sap-gen-abap → /sap-check-abap (+/sap-fix-abap)           │
   │  (docs-check runs ddic+process dimensions; check-abap covers        │
   │   naming·types·SQL·fm·syntax dimensions)                            │
   └───────────────────────────────────────────────────────────────────┘
                                            │   Z<PROG>.abap (+ sibling files)
                                            ▼
   ┌───────────────────────────────────────────────────────────────────┐
   │  DEPLOY                                                            │
   │  /sap-se11 (DDIC) → /sap-se91 (messages) → /sap-se38|se37|se24      │
   │            → /sap-activate-object  (text elements for reports)      │
   │  …each pulls a transport request via /sap-transport-request        │
   └───────────────────────────────────────────────────────────────────┘
                                            │
                                            ▼
   ┌───────────────────────────────────────────────────────────────────┐
   │  PROVE                                                             │
   │  /sap-atc  →  /sap-run-abap-unit                                    │
   └───────────────────────────────────────────────────────────────────┘
                                            │
                                            ▼
   ┌───────────────────────────────────────────────────────────────────┐
   │  SHIP                                                              │
   │  /sap-transport-readiness → /sap-se01 release → /sap-stms import   │
   │                                          DEV → QAS → (typed-SID) PRD │
   └───────────────────────────────────────────────────────────────────┘
```

你不必使用每一个步骤。最小可用的闭环是
`/sap-login` → 编写/粘贴 ABAP → `/sap-se38` → `/sap-atc`。其余一切的存在，都是为了让
这个闭环在客户的系统格局（landscape）上*值得信赖*。

**主动权始终在你手里。** Claude 提出建议；你来批准。你可以单独运行任意一个技能，顺序
不限。上面那条链条是推荐顺序，而非强制轨道。

---

## 2. 前提条件

### 2.1 工作站

| 要求 | 原因 | 检查方式 |
|---|---|---|
| **Windows 10 / 11** | SAP GUI Scripting 仅限 Windows；凭据用 Windows DPAPI 加密 | `winver` |
| **SAP GUI for Windows 7.70+** | 所有驱动事务码的技能 | SAP Logon → About |
| **已启用 SAP GUI Scripting（客户端侧）** | 必须允许 VBScript 引擎 | 见 §2.3 |
| **Claude Code CLI** | 运行技能的宿主 | `claude --version` |
| **SAP .NET Connector 3.1（32 位，.NET 4.0）** *（可选，但推荐）* | RFC 快速通道：TR 状态、FM 签名、激活验证、表读取 | 见 §2.4 |
| **Python 3.10+** *（可选）* | `sap-gen-code` 文档流水线的部分功能会用到 | `py --version` |

> **Shell 说明（对 Windows 很重要）。** 你可以从**任何你喜欢的 shell** 启动 `claude`
> —— cmd、PowerShell、Windows Terminal 都行。这不会改变技能的运行方式：
> 它们内部始终使用 **Windows PowerShell 5.1** + 32 位 `cscript`。**你不需要 `pwsh`。**
> 不要把 `chcp 65001` 或"Beta: Use Unicode UTF-8"当作 CJK 的"修复手段"——
> 那会破坏旧版/SAP 工具。CJK 的正确处理已内建在技能里。如果只是想*看到* CJK 字符，
> 请用配了 CJK 字体的 Windows Terminal。
> （完整细节：[`docs/windows-shell-and-encoding-faq.md`](windows-shell-and-encoding-faq.md)。）

### 2.2 SAP 服务器端开关

SAP GUI Scripting 必须在**两侧**都启用。服务器端是配置文件参数
**`sapgui/user_scripting = TRUE`**（在 RZ11 中设置，在 RZ10 中永久化）。
如果这由你的 Basis 团队管理，请让他们确认 DEV 系统上它是 `TRUE`。
工具内建了一个只读检查 —— 参见 [§4.4](#44-确认一切健康--sap-doctor) 中的 `/sap-doctor`。

### 2.3 在你的客户端上启用 SAP GUI Scripting

在 **SAP Logon → Options (Alt+F12) → Accessibility & Scripting → Scripting →**
勾选 **Enable Scripting**，并*取消勾选*"Notify when a script attaches to SAP GUI"
和"Notify when a script opens a connection"，这样技能就不会卡在一个弹窗上。
之后重启 SAP Logon。

### 2.4 SAP NCo 3.1（RFC）—— 需要下载什么

RFC 功能需要 [SAP .NET Connector 3.1](https://support.sap.com/en/product/connectors/msnet.html)。

> ✅ **先检查 —— 你可能已经有了。** 如果你安装了 **SAP GUI 7.7**，NCo 3.1
> 通常会被自动部署到 GAC 中。在下载任何东西之前，先检查这**两个**文件是否存在：
>
> ```text
> C:\Windows\Microsoft.NET\assembly\GAC_32\sapnco\v4.0_3.1.0.42__50436dca5c7f7d23\sapnco.dll
> C:\Windows\Microsoft.NET\assembly\GAC_32\sapnco_utils\v4.0_3.1.0.42__50436dca5c7f7d23\sapnco_utils.dll
> ```
>
> 如果**两个**都在，那就完成了 —— **无需下载或安装**。（具体的版本文件夹名可能略有
> 不同；只要 `GAC_32` 里有任何一对 `v4.0_3.1.0.*` 的 32 位 `sapnco` + `sapnco_utils`
> 都可以。）

如果它们缺失，**插件并不附带 SAP 二进制文件** —— 请用你的 S-User 账号自己从
SAP Service Marketplace 下载。你需要的是 **32 位、.NET Framework 4.0** 版本，
并**安装到 GAC**（安装程序选项"Install assemblies to GAC"）。即使没有 NCo，一切仍可
运行，只是基于 RFC 的校验会退回到仅 GUI，或被跳过。

### 2.5 你在 DEV 上会需要的 SAP 授权

你是以你自己的身份行事。要跑完整个流程，你需要一个具备以下能力的开发者：

- `S_DEVELOP` —— 创建/修改程序、FM、类、包、函数组。
- `S_CTS_ADMI` / 传输权限 —— 创建并释放传输请求
  （或者让 Basis 预先为你创建一个 TR）。
- DDIC 权限（`S_DDIC_ALL` 或等效）—— 创建域/数据元素/结构。
- 如果你的系统仍在强制 SSCR，则需要一个**开发者密钥 / 注册**（大多数现代系统已不再
  要求）。

如果你缺少其中之一，相关技能会带着 SAP 错误信息**大声失败** —— 它绝不会假装成功。

---

## 3. 安装插件

在一个 `claude` 会话中，添加 marketplace 并安装：

```text
/plugin marketplace add https://github.com/sapdev-ai/sap-dev
/plugin install sap-dev-core@sap-dev
```

`sap-dev-core` 是基础，也是唯一必装的插件。其余按需添加：

```text
/plugin install sap-gen-code@sap-dev      # spec → ABAP generation
/plugin install sap-migrate@sap-dev       # S/4HANA custom-code migration
/plugin install sap-tcd@sap-dev           # BP / MM01 / VA01 automation
```

> ℹ️ **每条 `/plugin install` 命令只装一个插件** —— 上面那几行请逐条运行。
> （Claude Code 目前不接受在一条 `/plugin install` 里安装多个插件。）

**激活新技能。** 安装（或更新）插件后，重新加载，让会话识别到新的 `/sap-*` 技能：

```text
/reload-plugins
```

如果你用的是 **Claude 桌面应用**（而非终端 CLI），请改为**重启应用** ——
`/reload-plugins` 可能无法完全刷新桌面端的技能列表。

**验证**：输入 `/`，你应该能在斜杠命令列表里看到 `/sap-login`、`/sap-dev-init`、
`/sap-se38` 等。如果在 `/reload-plugins`（或桌面端重启）之后它们仍然缺失，请重启
`claude` 会话，让它重新扫描插件。

> 你也可以直接*对* Claude *说话*。"登录到我的 SAP DEV 系统"、"创建一个数据元素
> ZHKDE_AMOUNT"、"部署这个报表"都会被分派到正确的技能。斜杠命令是显式形式；自然语言
> 是日常形式。

---

## 4. 首次设置

三个一次性动作：选一个**工作目录**、**保存一个连接**，以及**引导初始化开发环境**。

### 4.1 选一个工作目录（推荐，且持久）

工具集写入的一切 —— 你保存的连接、生成的代码、日志、缓存 —— 都存放在一个
**工作目录**（默认 `C:\sap_dev_work`）之下。在 Windows 用户级别设置一次，让它在插件
更新后依然存在：

```powershell
# In a normal PowerShell window, once:
setx SAPDEV_AI_WORK_DIR "D:\sapdev"
```

`/sap-login` 的引导流程也会主动提出帮你设置它，并写入一个持久指针
（`%APPDATA%\sapdev-ai\work_dir.txt`），让*当前*会话立即识别它。如果你跳过这一步，
就只会用到 `C:\sap_dev_work`。

工作目录下都放些什么：

| 路径 | 存放内容 |
|---|---|
| `runtime\connections.json` | 你保存的 SAP 连接（密码经 DPAPI 加密） |
| `runtime\…` | 会话/broker 状态、各连接的开发默认值 |
| `custom\` | 你的项目覆盖项：`customer_brief.md`、命名规则、转换规则 |
| `design_docs\` | 输入的设计文档 |
| `source_code\` | 生成的 ABAP + 每个文档的工作文件夹 |
| `logs\` | 结构化 JSONL 运行日志（`/sap-log-analyze` 读取这些） |
| `cache\fm_signatures\` | 按系统缓存的 FM 签名 |
| `temp\` | 每次运行的临时空间 |

### 4.2 保存一个 SAP 连接 —— `/sap-login`

运行：

```text
/sap-login --add
```

系统会向你询问连接详情。**请一次性全部提供** —— 该技能也会读取 SAP Logon 自己的系统
格局，所以你也可以直接说"登录到我的 S4D pad 条目"。有两种端点风格：

**应用服务器（直连）连接**

| 字段 | 示例 |
|---|---|
| `sap_logon_description` | `S4H [S42022.example.com]` |
| `sap_application_server` | `S42022.example.com` |
| `sap_system_number` | `00` |
| `sap_client` | `100` |
| `sap_user` | `DEVUSER` |
| `sap_password` | `••••••••` |
| `sap_language` | `EN` |

**消息服务器（负载均衡）连接**

| 字段 | 示例 |
|---|---|
| `sap_logon_description` | `S4D [msgsrv.example.com]` |
| `sap_message_server` | `msgsrv.example.com` |
| `sap_logon_group` | `PUBLIC` |
| `sap_system_id` | `S4D` |
| `sap_client` | `100` |
| `sap_user` | `DEVUSER` |
| `sap_password` | `••••••••` |
| `sap_language` | `EN` |

会发生什么：

1. Claude 生成一段一次性登录 VBScript，并通过 SAP GUI 连接。
2. 如果你要求，它会通过 NCo 验证 RFC 连通性。
3. 它会主动提出**保存配置**，用 **Windows DPAPI** 加密密码
   （存储为 `dpapi:…`，只有这台机器上你的 Windows 账号才能解密）。
4. 它会**把这次对话固定（pin）到这个连接**，使后续每个技能都驱动正确的系统。如果你在
   同一个 SAP 系统上再开一个 `claude` 对话，内建的*会话 broker* 会生成一个独立的 SAP
   会话，让两者不会相互冲突。

登录后你会落在标准的 **SAP Easy Access** 菜单上，现在它由 CLI 驱动。

**管理多个客户 / 系统**（你会有很多）：

```text
/sap-login --list                 # show every saved profile
/sap-login --switch S4D           # switch this conversation to S4D (by SID)
/sap-login --switch S4D/200/DEV2  # disambiguate by SID/client/user
/sap-login --set-default S4D      # default target for new conversations
/sap-login --delete <id>          # remove a profile (asks first)
/sap-login --check                # health-check all profiles (RFC, DNS, live sessions)
```

每个对话固定到一个配置；子代理继承这个固定关系。这正是你让"我在客户 A 的 QAS 上的
修复"和"我在客户 B 的 DEV 上的构建"永不相互串扰的方式。

### 4.3 引导初始化开发环境 —— `/sap-dev-init`

```text
/sap-dev-init
```

这是"让我的沙箱准备就绪"的步骤。它是**幂等的** —— 可以安全地重复运行；它会检查已有
什么，只创建缺失的部分。它按顺序执行：

1. **权限检查** —— 确认你有一个活动的 GUI 会话（以及 RFC 所需的凭据）。
2. **自愈** —— 从你的设置中清除一个陈旧的/已释放的开发传输请求。
3. **在 SAP GUI Security 中信任你的工作目录**（每个 Windows 账号一次性）—— 这样技能
   所做的文件 IO 就不会被 SAP GUI Security 弹窗拦截。
4. **传输请求** —— 询问你的 TR 策略（见下文），并解析/创建一个 TR。
5. **包** —— 创建你的开发包（默认 `ZCMDEVAI`）。
6. **函数组** —— 创建你的函数组（默认 `ZFGDEVAI`）。
7. **DDIC 脚手架** —— 域 `ZCMD_RFCVAL`、数据元素 `ZCMDE_RFCVAL`、结构
   `ZCMST_RFC_PARAM`、表类型 `ZCMCT_RFC_PARAM`。
8. **通用 RFC 包装 FM** `Z_GENERIC_RFC_WRAPPER_TBL`（标记为 remote-enabled）——
   让工具集能够安全地通过 RFC 调用非 RFC 函数模块。
9. **工具程序** `ZCMRUPDATE_ADDON_TABLE` —— 供 `/sap-update-addon` 使用。

当被问到 **TR 策略**（`way_to_get_transport_request`）时，选一个：

| 策略 | 行为 | 适用于 |
|---|---|---|
| `DEFAULT` | 复用一个固定的开发 TR；仅当它为空/已释放时才询问 | 沙箱上的单人开发 |
| `ASK` | 每次都询问用哪个 TR（并提供记住的选项） | 跨多个 TR 工作 |
| `CREATE_NEW` | 总是新建一个全新 TR；从不持久化 | 一个对象一个 TR 的纪律 |

你还会选择新 TR 的**描述**如何生成（`ASK` / `PATTERN` / `FIXED` / `RANDOM`）。这些
选择**按连接**保存，因此每个客户系统都会记住自己的策略。

> 📷 *图 1 —— `/sap-dev-init` 创建的对象，显示在包 `ZCMDEVAI`（SE80）中。
> 包装 FM、工具程序和 DDIC 脚手架都在这里。*（截图为英文版 SAP 界面）
>
> ![包 ZCMDEVAI 中的 dev-init 对象](images/02-dev-init-package.png)

**随时检查它**（只读）：

```text
/sap-dev-status
```

它为每个产物（TR、包、函数组、包装 FM + 其 DDIC、工具程序）打印一行，外加一个
`STATUS:` 摘要。退出码 0 = 健康。

### 4.4 确认一切健康 —— `/sap-doctor`

在你的第一次真正构建之前，运行这个只读预检：

```text
/sap-doctor
```

它检查 GUI scripting、NCo/配置、RFC 连通性、客户端可修改性，以及开发环境产物，并为
**每个失败打印一条可操作的修复建议**。它不改变任何东西。把一次干净的 `/sap-doctor`
当作你的放行绿灯。

---

## 5. 客户简介（Customer Brief）

这是你每个项目里最有价值的 10 分钟。**客户简介**是一份一页的表单，它告诉
`/sap-gen-abap` 你项目的*上下文* —— 版本、命名空间、包、消息类、质量标准 —— 这样
生成的 ABAP 就贴合客户的规范，而不是泛泛而生。

把模板复制到你的 `custom` 文件夹并填写：

```text
{work_dir}\custom\customer_brief.md
```

（随附的模板是 `plugins/sap-dev-core/shared/templates/customer_brief.md`；
一个填好的示例是 `customer_brief_sample.md`。当你的登录/模板语言为 JA 时，会自动选用
日文变体 `customer_brief_JA.md`。）

简介捕获的内容（节选）：

| 章节 | 驱动…… |
|---|---|
| **1. 系统** —— ABAP 版本、Unicode、登录语言、时区 | 现代语法 vs 经典语法、代码页处理 |
| **2. 命名空间与对象** —— `Z`/`Y` 前缀、子前缀（`ZHK`）、默认包、消息类 | 每一个生成对象的名称 |
| **3. 可复用工具** —— 优先使用的现有 Z 类/FM | `MODE_REUSE` —— 不重新实现已存在的东西 |
| **4. 数据量** —— 每种对象类型的 小 / 中 / 大 | `SELECT SINGLE` vs `INTO TABLE` vs `PACKAGE SIZE` |
| **5. 授权** —— 各领域的 AUTHORITY-CHECK 对象 | 生成的权限检查 |
| **6. 质量标准** —— 是否要求 ABAP Unit？是否 ATC 门禁？现代语法？OOP？方法最大长度？注释语言 | 哪些发现项会阻止部署；代码的形态 |

该简介被 `/sap-docs-extract`、`/sap-gen-abap`（强制上下文）和 `/sap-check-abap`
（用于决定哪些发现项具有阻断性）读取。填一次，每份规格都受益。

---

## 6. 从设计文档生成 ABAP

`sap-gen-code` 流水线把一份**设计文档**（客户给你的功能规格 —— Excel、Word 或 PDF）
变成**经过校验、可直接部署的 ABAP 源代码**。每一步都把纯文本文件写入一个*工作文件夹*，
因此你可以在任何阶段检查并手工编辑。

### 6.0 标准顺序

```text
(/sap-docs-layout)        # optional: customise the spec workbook layout
 /sap-docs-extract        # REQUIRED: document → structured *.txt files
(/sap-docs-convert)       # optional: apply customer field/type/flag renames
 /sap-docs-check          # recommended: validate the spec (ddic + process dimensions)
 /sap-gen-abap            # REQUIRED: generate Z<PROG>.abap (+ sibling files)
 /sap-check-abap          # recommended: naming / types / SQL / contracts / coverage / CALL FUNCTION / syntax
 /sap-fix-abap            # if check-abap found auto-fixable issues
```

### 6.1 抽取 —— `/sap-docs-extract`

```text
/sap-docs-extract C:\work\design\CustomerUpload.xlsx
```

输入可以是 `.xlsx` / `.docx` / `.doc` / `.pdf`、一个已有的工作文件夹，或一个
`_raw.txt`。它会创建一个工作文件夹，并把文档转储成分类的文本文件 —— 你最关心的那些：

| 文件 | 内容 |
|---|---|
| `{doc}_PGM_summary.txt` | 程序 id/名称/类型/包/版本 |
| `{doc}_process.txt` | **处理逻辑 —— 生成的主输入** |
| `{doc}_domains.txt` / `_dataElements.txt` / `_tables.txt` | DDIC 定义 |
| `{doc}_selection_definition.txt` | 选择屏幕字段 |
| `{doc}_errorMsgs.txt` | 消息类条目 |
| `{doc}_textElements.txt` | 文本符号 |
| `{doc}_interface.txt` | 输入/输出/异常（用于 FM） |
| `{doc}_golden.txt` | 测试场景（→ ABAP Unit） |
| `{doc}_deps.txt` | 声明的依赖（FM、BAPI、表） |

这一步是**离线**的 —— 不需要 SAP 连接。

### 6.2 转换 *（可选）* —— `/sap-docs-convert`

```text
/sap-docs-convert <work-folder> [<rules.tsv>]
```

对抽取出的文件应用客户特定的归一化规则（旧字段名 → 规范名、旧 DDIC 类型 → 规范类型、
标志值 → 键/值）。如果你的规格已经是工具集预期的形态，就**跳过它**。会先拍一个
`.pre-convert/` 快照，所以可逆。

### 6.3 校验规格 —— `/sap-docs-check`

```text
/sap-docs-check <work-folder> [<sap-logon-description>]   # 默认运行两个维度
/sap-docs-check <work-folder> --dimension ddic            # 仅 DDIC 维度
/sap-docs-check <work-folder> --dimension process         # 仅流程维度
```

一个技能，两个维度（默认运行输入文件存在的两个维度）:

- **ddic** 维度校验域/数据元素/表：命名、有效的 DDIC 类型、CURR/QUAN 参考完整性、
  域↔数据元素↔表的交叉引用。传入一个登录描述，还会通过 RFC 对照**实时**字典进行校验。
- **process** 维度标记含糊/矛盾的逻辑、未定义的字段/表，以及类型不匹配；可选地把
  table.field 引用与实时 SAP 对照校验。

每个维度都会写出一个制表符分隔的 `check_result_*.txt`（ddic / process），你可以在 Excel 中打开。**只列出问题**
—— 空结果意味着干净。在规格文本文件中修复问题，重新运行，然后继续。

### 6.4 生成 —— `/sap-gen-abap`

```text
/sap-gen-abap <work-folder>\{doc}_process.txt
```

它读取 process 文件、同级的 `_*.txt` 文件，**以及你的客户简介**，通过 RFC 预取实时的
FM/结构/授权签名（按系统缓存），并产出：

| 产物 | 用途 |
|---|---|
| **`Z<PROGRAM_ID>.abap`** | 交付物 —— ABAP 源代码 |
| `Z<PROGRAM_ID>.deps.txt` | 依赖清单（交给 Basis） |
| `Z<PROGRAM_ID>.messages.txt` | 消息类填充 → `/sap-se91` |
| `Z<PROGRAM_ID>.text_elements.txt` | 选择文本 + 文本符号 → `/sap-se38` |
| `Z<PROGRAM_ID>.traceability.txt` | 规格章节 → ABAP 行的审计映射 |
| `Z<PROGRAM_ID>_TEST.abap` | ABAP Unit 类（当简介要求测试时） |

它可以生成**报表/帳票（批处理）**、**对话/模块池**程序，以及**函数模块 / RFC**。
简介负责引导细节：现代 vs 经典语法、OOP vs FORM 脚手架、按数据量分档的性能模式、
AUTHORITY-CHECK 的放置位置、你的消息类，以及注释语言。

生成器已经强制执行那些通常会导致 ATC 发现项的规则 —— 不用 `SELECT *`、类方法内不用
`MESSAGE e…`、不用 `LOOP … WHERE … EXIT`、货币字段带上其参考字段、FM 调用参数与实时
签名匹配，等等 —— 因此代码*一出生就接近干净*。

### 6.5 校验生成的代码 —— `/sap-check-abap`

```text
/sap-check-abap <work-folder>\Z<PROGRAM_ID>.abap     # all dimensions (see below)
```

一个技能，多个**维度**（原 `/sap-check-fm` 现为 `fm` 维度；新增 `syntax` 维度）：
- **naming / type / sql / unused / contract / spec / conv** —— 变量命名（对照你的规则）、
  数据类型、SQL 字段名、未使用的变量、生成契约（行长、`SELECT *`、消息路由、文本符号），
  以及**规格覆盖度**。默认离线；加上连接即可做实时的类型/SQL 校验。
- **fm** —— 通过 RFC 把每一个 `CALL FUNCTION` 与**真实**的 FM 签名对照校验（参数名、所属节、
  必填标志、类型兼容性、结构字段），在臆造参数撞到 SE37 之前抓住它。
- **syntax** —— 无头的编译器级语法检查（通过 RFC 的 `EDITOR_SYNTAX_CHECK`），在任何 GUI
  上传之前离线抓住真实语法错误。对自包含程序执行；对 include / FM 片段 / 类池会报告
  `SYNTAX_COULD_NOT_CHECK`（它们由部署技能的 Ctrl+F2 在上下文中校验）。

如果发现可自动修复的问题，运行修复器（会先写一个带时间戳的 `.bak`）：

```text
/sap-fix-abap <work-folder>\Z<PROGRAM_ID>.abap
```

`fix-abap` 重命名违反命名规则的变量、注释掉未使用的变量、应用语法安全的改写、修复
`CALL FUNCTION` 参数（原 `fix-fm`，已并入），并驱动一个有界的 AI 语法修复循环。任何无法
安全自动修复的问题（例如 `TYPE_NOT_FOUND`）会被标记出来交给你处理。反复运行检查器，
直到它干净为止。

每个检查器都会在源代码旁边写一个制表符分隔的结果文件（check-abap 是
`Z<PROGRAM_ID>.check.tsv`）—— 每个发现项一行，带有 **Code**、**Severity**、**Line** 和
**Fix Advice** 列，你可以在 Excel 中打开。空结果意味着干净。

---

## 7. 部署代码

现在把产物推入 SAP。**顺序很重要** —— DDIC 要在使用它的程序之前，消息类要在从中发消息
的程序之前：

```text
1. /sap-se11   <type> <name> <def-file>     # domains → data elements → structures → tables
2. /sap-se91   <MSGCLASS> <messages-file>   # populate the message class
3. /sap-se38   <PROGRAM>  <Z<PROG>.abap>    # (or /sap-se37 for FMs, /sap-se24 for classes)
4. text elements                            # apply Z<PROG>.text_elements.txt (reports)
```

每个部署技能都：检查对象是否存在 → 创建或更新 → **语法检查** → 保存 → **激活** ——
然后通过 RFC**验证**激活（`PROGDIR.STATE = A`、`DWINACTIV`、状态栏 `MessageType = S`）。
它绝不会对一个未激活或语法损坏的对象报告成功。

### 7.1 程序 / 报表 —— `/sap-se38`

```text
/sap-se38 ZHKMM001R01 C:\sapdev\source_code\work\...\ZHKMM001R01.abap
```

源代码可以是**文件路径或粘贴的 ABAP**。对于报表，该技能还会在激活后应用选择文本 /
文本符号元素（来自生成的 `.text_elements.txt`）。其他模式：`check-and-fix`（无源代码 →
打开、语法检查、修复、重新上传、激活）、`change-attributes`（标题/状态/类型），以及
`delete`（会先询问）。

> 📷 *图 2 —— 一个由 `/sap-gen-abap` 生成、用 `/sap-se38` 部署的报表，在 S4G 演示系统
> 的 SE38 中显示为 **Active**。生成的头部注释块记录了生成器从客户简介推导出的 `MODE_*`
> 标志（ABAP 7.54、经典语法、开启单元测试、中等数据量档、EN 注释）。*（截图为英文版 SAP 界面）
>
> ![在 SE38 中部署并激活的生成报表](images/04-se38-program.png)

### 7.2 函数模块 —— `/sap-se37`

```text
/sap-se37 Z_HK_UPLOAD_FILE C:\...\Z_HK_UPLOAD_FILE.abap --function-group=ZHKFG01
```

源代码必须是**完整的函数 include**（`FUNCTION … ENDFUNCTION.`，带有
`*"Local Interface:` 块）。模式还包括 change-attributes（短文本 / 处理类型 /
设为 remote-enabled）、重新分配到另一个函数组，以及删除。

### 7.3 类与接口 —— `/sap-se24`

```text
/sap-se24 ZCL_HK_UPLOAD_PROCESSOR C:\...\ZCL_HK_UPLOAD_PROCESSOR.abap
/sap-se24 ZCX_HK_ERROR <file> --exception --with-message   # exception class tied to T100
/sap-se24 ZCL_HK_FOO <file> --test-source=<test.abap>        # deploy WITH local test classes
```

源代码是**完整的** `CLASS … DEFINITION … IMPLEMENTATION … ENDCLASS`。（工具集会替你
处理 UTF-8/编码方面的细节。）

### 7.4 DDIC 对象 —— `/sap-se11`

```text
/sap-se11 DOMAIN       ZHKDM_AMT     <def.tsv>
/sap-se11 DATAELEMENT  ZHKDE_AMOUNT  <def.tsv>
/sap-se11 STRUCTURE    ZHKS_ITEM     <def.tsv>  --enhancement-category=NOT_EXTENSIBLE
/sap-se11 TABLE        ZHKT_LOG      <def.tsv>
```

从**制表符分隔的定义文件**处理全部九种 DDIC 类型（表、视图、数据元素、结构、表类型、
类型组、域、搜索帮助、锁对象）。预检引用的域/数据元素，为表/结构设置增强类别，并在激活
后通过 RFC 验证激活版本。（删除模式也存在，需确认。）

> **定义文件陷阱：** `.def`/`.tsv` 文件必须包含**真正的 TAB 字节**，而不是字面字符
> `\t`。如果你用一个普通的文本工具写它们，请确保 tab 就是 tab。该技能会自动修复常见的
> 损坏，但真正的 tab 最稳妥。

### 7.5 消息类 —— `/sap-se91`

```text
/sap-se91 ZHKMSG01 <messages.txt>     # e.g. the generated Z<PROG>.messages.txt
```

消息是制表符分隔的 `number<TAB>text`（占位符 `&1`–`&4`）。如有需要会创建该类；当文本
已存在时复用现有的消息号。

### 7.6 收尾零散项 —— `/sap-activate-object`

如果有任何东西仍处于未激活状态（例如一次失败的激活），单独激活它：

```text
/sap-activate-object PROGRAM ZHKMM001R01
/sap-activate-object CLASS   ZCL_HK_UPLOAD_PROCESSOR
```

它按类型路由到正确的事务码，自动处理*未激活对象工作列表*弹窗，并通过 `PROGDIR` /
`DWINACTIV` 验证。

### 7.7 传输如何处理 —— 你永远不需要往部署技能里输入 TR

每个需要传输请求的部署技能都会询问 **`/sap-transport-request`** —— 这个唯一入口会应用
你的 `way_to_get_transport_request` 策略（`DEFAULT` / `ASK` / `CREATE_NEW`）。当需要一个
新 TR 时，它委托给 `/sap-se01`（默认创建一个 **Workbench** 请求，并根据你的模板渲染
描述）。你在 `/sap-dev-init` 里设置一次策略；此后，部署就只是*顺畅地流动* —— 正确的 TR
会为你解析好，并且任务 TR 按对话隔离，使并行工作永不破坏共享默认值。

你仍可以在需要时直接管理 TR：

```text
/sap-se01 create W "ZHK month-end report"   # create a workbench TR
/sap-se01 release DEVK900123                 # release (asks first — irreversible)
/sap-se01 delete  DEVK900123                 # delete an unreleased TR (asks first)
```

---

## 8. 质量门禁

### 8.1 ATC —— `/sap-atc`

把 ABAP Test Cockpit 作为门禁端到端地运行：

```text
/sap-atc PROGRAM ZHKMM001R01
/sap-atc PROGRAM ZHKMM001R01 --variant=S4HANA_READINESS --max-priority=2
```

它构建一个对象集，创建并运行一个 ATC 运行系列，轮询监视器直到完成，并读取
**Priority 1 / 2 / 3** 发现项计数。它应用你的 `MAX_PRIORITY` 门禁（默认 2 → P1 **和**
P2 阻断；P3/P4 仅告警），并把发现项写入一个 TSV。失败（FAIL）时它会自动下钻到每个发现项
的详情。

```
PRIORITY_COUNTS: P1=0 P2=1 P3=3
GATE_VERDICT: FAIL  P1=0 P2=1 P3=3 (threshold=2 → P2 blocks)
FILE: …\ATC_R_260709_101500.txt.findings.tsv (4210 bytes)
```

对象类型：`PROGRAM`、`CLASS`、`INTERFACE`、`FUGR`、`DDIC`……（对于一个函数模块，传入它的
**FUGR**）。修复这些发现项（通常通过 `/sap-fix-abap` 或一次有针对性的编辑 + 重新部署），
然后反复运行直到 `GATE_VERDICT: PASS`。

### 8.2 ABAP Unit —— `/sap-run-abap-unit`

如果生成器产出了一个测试类（因为你的简介要求了测试），运行它：

```text
/sap-run-abap-unit ZHKMM001R01_TEST
/sap-run-abap-unit ZCL_HK_UPLOAD_PROCESSOR --with-coverage --min-coverage=80
```

它通过 SE38/SE24 执行单元测试，报告每个方法的通过/失败，并给出一个判定。
`--with-coverage` 还会额外测量代码覆盖率，并可以基于一个最低百分比设门禁。

---

## 9. 传输就绪检查、释放与 STMS

### 9.1 释放前门禁 —— `/sap-transport-readiness`

在你释放之前，检查这个 TR 是否真的可以发运：

```text
/sap-transport-readiness --current                 # the conversation's dev TR
/sap-transport-readiness DEVK900123 --run-atc --include-unit-tests --strict
```

RFC，只读。它检查未释放的子任务、未激活对象、坐在一个可传输请求里的 local/$TMP 对象，
并（可选地）汇入 ATC 和 ABAP-Unit 判定。它把一切汇总成
**GO / GO_WITH_WARNINGS / NO_GO**，附带每个发现项的整改清单，以及一个诚实的"无法检查"
小节。

```
READINESS: tr=DEVK900123 verdict=GO_WITH_WARNINGS block=0 warn=2 info=1 objects=5
```

退出 0 = 可安全释放；退出 1 = NO_GO，请先修复。

### 9.2 释放 —— `/sap-se01 release`

```text
/sap-se01 release DEVK900123
```

释放该请求及其任务。**不可逆 —— 它会先要你确认。**

### 9.3 让它走过系统格局 —— `/sap-stms`

读取导入队列和日志，并把一个已释放的 TR 沿 DEV → QAS → PRD 导入：

```text
/sap-stms status DEVK900123 --route          # where is it in the route?
/sap-stms import DEVK900123 --to S4Q          # import into QAS
/sap-stms logs   DEVK900123 --system S4Q      # read the return code (RC) afterwards
```

`/sap-stms` **读取导入日志里真实的返回码**（RC 0 = OK、4 = 警告、8 = 错误、12 = 致命）
—— 它不会轻信队列里那一行"done"。

**生产被刻意设计为难以误触。** 导入到一个生产系统（生产允许列表上的某个 SID）需要你
**把目标 SID 原样回敲**并显式确认，并且要在技能向你展示该 TR 的对象清单之后。没有任何
快捷标志。这是工具集在拒绝让一条走神的命令碰到生产。

---

## 10. 一个完整的实战示例

场景：客户交给你 `MaterialUpload.xlsx` —— 一份报表规格，要读取一个物料文件并创建它们。
你的简介设置子前缀 `ZHK`、包 `ZHKA011`、消息类 `ZHKMSG01`、ABAP Unit"强制"、ATC
"优先级 1+2 门禁"。

```text
# --- one-time, already done: /sap-login, /sap-dev-init, customer_brief.md filled ---

# 1. Generate
/sap-docs-extract C:\sapdev\design_docs\MaterialUpload.xlsx
/sap-docs-check         C:\sapdev\source_code\work\MaterialUpload_20260626\
/sap-gen-abap C:\sapdev\source_code\work\MaterialUpload_20260626\MaterialUpload_process.txt
/sap-check-abap C:\sapdev\source_code\work\MaterialUpload_20260626\ZHKMM001R01.abap
#   → if findings: /sap-fix-abap … then re-check until clean

# 2. Deploy
/sap-se91 ZHKMSG01 C:\sapdev\source_code\work\MaterialUpload_20260626\ZHKMM001R01.messages.txt
/sap-se38 ZHKMM001R01 C:\sapdev\source_code\work\MaterialUpload_20260626\ZHKMM001R01.abap
#   (apply the generated text elements when prompted)

# 3. Prove
/sap-atc PROGRAM ZHKMM001R01 --max-priority=2
/sap-run-abap-unit ZHKMM001R01_TEST

# 4. Ship
/sap-transport-readiness --current --run-atc --include-unit-tests
/sap-se01 release <your-TR>
/sap-stms import <your-TR> --to S4Q
```

实践中你不会逐条输入这些 —— 你会说*"从这份规格生成 MaterialUpload 报表，检查它，并把它
部署到 DEV"*，然后在 Claude 走到每个受门禁的步骤时逐一批准。上面的命令是引擎盖下正在
发生的事。

### 10.1 —— 捷径：把整个闭环交给 `abap-developer` 代理

§6–§8 中的一切，都可以由单个子代理替你驱动 —— **`abap-developer`**
（随 `sap-dev-core` 附带）。它是一个资深 ABAP 开发者人设，会读取你的客户简介、据此设置
`MODE_*` 标志，并端到端地编排 `/sap-*` 技能。你描述*结果*；它跑流水线，在每个受门禁的
步骤停下来等你批准。它有**三种模式**，由你措辞的方式来选择：

| 模式 | 你可以这样说…… | 它会运行什么 |
|---|---|---|
| **build** | "从 `…\MaterialUpload.xlsx` 构建 `ZHKMM001R01` 并部署到 DEV" | 抽取 → 校验规格 → DDIC + 消息类 → 生成 → 检查/修复 → **（问你）** → 部署 → 激活 → 文本元素 → ATC → 单元测试 |
| **fix** | "修复 `ZHKMM001R01`" / "让 `ZLEGACY_RPT` 通过 ATC" | `/sap-check-fix` 调度器（≤3 轮自动修复）→ ATC 复检 → 报告 |
| **deploy** | "把 `…\ZHKFOO.abap` 部署到 DEV" | 分类源代码 → 验证依赖 → **（问你）** → 解析 TR → 部署 → ATC |

通过点名调用它，或者直接把任务说出来 —— Claude 会自动分派给它：

> **你：** *用 abap-developer 代理从*
> *`C:\sapdev\design_docs\MaterialUpload.xlsx` 构建 MaterialUpload 报表并部署到 DEV。*

随后该代理会自行运行：

1. **预检** —— 解析你的工作目录；读取 `customer_brief.md` 并设置
   `MODE_OOP / MODE_UNIT_TESTS / MODE_PERF_BAND / ATC_MAX / …`；确认有一个活动的 SAP
   会话（必要时运行 `/sap-login`）；**检查它已固定到你点名的那个系统**（这样
   "在 S4H 上部署"就不会悄悄落到 S4D 上）；并运行 `/sap-dev-status` 来确认 dev-init 产物
   存在。
2. **构建** —— `/sap-docs-extract` → `/sap-docs-check`
   → 部署规格的 DDIC 对象（`/sap-se11`）和消息类（`/sap-se91`）
   → `/sap-transport-request` → `/sap-gen-abap` → `/sap-check-abap`
   （全部维度，+ `/sap-fix-abap`，最多 3 轮）。
3. **在第一次写入 SAP 之前问你**：
   > "已生成 `ZHKMM001R01.abap`（320 行）。测试：`ZHKMM001R01_TEST.abap`
   > （4 个方法）。质量检查通过。计划：部署到包 `ZHKA011`，使用 TR
   > `DEVK900123`，激活，运行 ATC 优先级 ≤ 2。继续吗？（yes / show source / cancel）"
4. **部署 + 证明** —— 在你说*yes*之后：`/sap-se38`（部署 → 激活 → 应用文本元素）→
   `/sap-atc` → 部署并运行 `/sap-run-abap-unit`。
5. **最终报告** —— 一份 SUMMARY（模式、状态、对象、TR、ATC 结果、测试）、一个
   ARTIFACTS 清单（源代码、依赖、可追溯性、记录稿），以及 NEXT STEPS。

按契约，该代理**不会**做的事（它在拒绝时会引用规则文件）：

- 未经你显式的"yes"就部署任何东西（上面的第 3 步）。
- 手写 ABAP —— 生成永远经过 `/sap-gen-abap`（它拥有手写代码无法查阅的实时
  FM / AUTHORITY-CHECK / DDIC 结构缓存）。
- 绕过 ATC 优先级 1/2 的发现项 —— 它会把它们浮出水面并让你来决定。
- 悄悄重命名你规格里的对象 —— 如果某个名称在**目标系统上**已存在，它会停下来询问
  （原地复用 / 加后缀递增 / 中止）。
- 对 SAP 标准表写 SQL，或者直接向你索要一个 TR 号。

每一次技能调用都会被追加到一份审计**记录稿**，位于
`{work_dir}\temp\abap_developer_transcript_*.txt` —— 这是你第二天早上可以回看的
"它做了什么、为什么"的踪迹。

**一个真实、完整的提示。** 实践中你给出的指令会比一行更丰富 —— 代理会把每个子句映射到
一个步骤或一个 `MODE_*` 标志。一个真实的构建提示长这样（这份规格就随仓库附带，所以你
可以原样运行它）：

> *请基于以下设计文档使用 **abap-developer** 创建对应的程序，并将其部署到 **S4D**
> 系统。*
>
> *创建设计文档中指定的包和新请求，并将它们用作本任务的默认选择。*
>
> *请执行完整流程，避免使用先前已生成的代码。请用 SAP 的登录语言文本作为代码注释。*
>
> *部署程序后，用此程序创建三个物料。*
>
> *生成单元测试程序并成功执行它。*
>
> *请使用 EN 登录 SAP 系统。*
>
> *记录发现的任何问题。*
>
> `C:\Work\Dev\ClaudeCodeDev\sapdev-ai\marketing\Sample\spec_MaterialUpload_EN.xlsx`

代理如何解读每一条指令：

| 你的措辞 | 代理做什么 |
|---|---|
| "把它部署到 **S4D** 系统" + "用 **EN** 登录……" | 运行 `/sap-login --lang EN`，然后确认会话已固定到 **S4D**（步骤 0.3a）—— 若它被固定到了别处，则停下来询问 |
| "创建设计文档中指定的包和新请求，并将它们用作本任务的默认选择" | 解析规格的包 + 一个**新**传输请求，创建它们，并把它们固定为这次对话的**会话级**开发默认值，使后续每个技能都复用它们 |
| "执行完整流程，避免使用先前已生成的代码" | 全新地跑完整构建流水线；通过 RFC 验证规格的对象名在 **S4D 上**无冲突，并原样使用它们（在复用/加后缀递增一个已存在的名称之前会询问） |
| "用 SAP 的登录语言文本作为代码注释" | 把 `MODE_COMMENT_LANG` 设为登录语言（此处为 EN） |
| "生成单元测试程序并成功执行它" | 产出 `Z…_TEST.abap`，部署它，并运行 `/sap-run-abap-unit` —— 一次失败的运行会中止构建 |
| "用此程序创建三个物料" | 激活后，运行已部署的报表来创建三个物料作为冒烟测试 |
| "记录发现的任何问题" | 把每个问题记录到运行记录稿，并在最终报告中浮出水面 |
| `…\spec_MaterialUpload_EN.xlsx` 路径 | 交给 `/sap-docs-extract` 的设计文档 |

在第一次写入 SAP 之前，你仍然要批准那个唯一的、受门禁的"继续吗？"提示。

> 配套的 **`cc-migration-engineer`** 代理（在 `sap-migrate` 中）为一场 S/4HANA 自定义代码
> 迁移战役做同样的编排工作。

---

## 11. Day-2 技能

除了绿地（green-field）式的构建并部署，工具集还覆盖 SIer 实际上花费最多时间的工作：

**理解现有代码**

```text
/sap-explain-object PROGRAM ZLEGACY_REPORT     # source + call map + explanation dossier
/sap-where-used-list TABLE ZHKT_LOG            # cross-reference
/sap-impact-analysis PROGRAM ZLEGACY_REPORT    # risk band before you change it
/sap-compare PROGRAM ZHKMM001R01               # same object across two saved systems
/sap-explain-object ZHKMM001R01 --spec         # turn an object into a spec document
```

**诊断与修复事故**

```text
/sap-diagnose "users get a dump posting goods receipt"   # fans out ST22/SM13/SM12/SLG1/SM37
/sap-st22 --deep                                          # short-dump detail
/sap-fix-incident <root-cause>                            # test-first fix in DEV, behind a TR
```

`/sap-fix-incident` 把闭环从一个根因，一直闭合到一个**经测试验证的**、部署在 DEV、藏在
一个传输请求之后的自定义代码修复 —— 受门禁约束，绝不碰标准代码或生产。

**S/4HANA 自定义代码迁移**（`sap-migrate` 插件）

```text
/sap-cc-campaign init        # start a tracked migration campaign
/sap-cc-inventory            # enumerate custom Z/Y objects in scope
/sap-cc-usage                # overlay runtime usage → what's actually used
/sap-cc-analyze              # S/4HANA-readiness ATC over the kept objects
/sap-cc-triage               # classify findings into remediation tiers
/sap-cc-remediate            # auto-fix the mechanical (R1) changes on a sandbox
```

---

## 12. 安全模型

工具集的构建目标，就是能在客户的系统格局上被信任。它的保证如下：

- **不对 SAP 标准表静默写入。** 变更都经过 SAP 自己的写入 API；如果不存在这样的 API，
  技能就停下来询问。
- **不擅自部署。** 除非是你要求的（或者该技能*本身*就是你调用的部署技能），否则技能不会
  创建或部署对象。
- **每个不可逆操作都会确认。** TR 释放、对象删除，以及**生产 STMS 导入**都会停下来等
  显式确认；生产还额外要求你把 SID 回敲一遍。
- **没有假成功。** 部署通过 RFC 验证激活；ATC 读取真实的优先级列；STMS 读取真实的返回
  码。"无法检查"会被如实报告，绝不会被报成"通过"。
- **你的凭据，你的机器。** 密码经 DPAPI 加密，只有这台工作站上你的 Windows 账号能解密，
  且永不离开它。
- **一个对话 = 一个 SAP 会话。** 会话 broker 让并行的对话不会去驱动彼此的会话。

---

## 13. 疑难排查与常见问题

**`/sap-login` 报"Could not get SAP Scripting Engine."**
你客户端上的 Scripting 被禁用了。启用它（SAP Logon → Options → Scripting）并重启
SAP Logon。如果仍然失败，说明服务器参数 `sapgui/user_scripting` 是 `FALSE` ——
让 Basis 把它设为 `TRUE`（RZ11）。

**某个技能卡在一个"SAP GUI Security"弹窗上。**
那是文件 IO 的信任对话框。`/sap-dev-init` 的步骤 3 会为当前 Windows 账号预先信任你的
工作目录。如果它再次出现，重新运行 `/sap-dev-init`（或关闭所有 SAP Logon 窗口并重启
一次，让规则持久生效）。

**RFC 步骤报"destination not found" / NCo 错误。**
SAP NCo 3.1 必须是 **32 位、.NET 4.0** 版本，并**安装到 GAC**。技能从
Windows PowerShell 5.1（32 位）调用它。请用"Install assemblies to GAC"选项重新安装。
没有它，一切非 RFC 的功能仍可运行。

**我的 TR 被释放了，现在部署失败。**
`/sap-dev-init` 会自愈一个陈旧的开发 TR；或者设置一个新的。当
`way_to_get_transport_request=ASK` 时，下次部署它会直接向你索要一个 TR。

**部署"成功"了，但对象并未激活。**
它不会 —— 技能会通过 RFC 验证激活，并报告 `ACTIVATION_FAILED` / `COULD_NOT_CHECK`，
而不是一个假成功。读取所报告的激活日志行，并修复其原因（通常是某个你需要先部署的缺失
DDIC 依赖）。

**CJK 注释/文本出现乱码。**
不要改 `chcp` 或系统区域设置。技能无论你的控制台如何，都会通过 UTF-8 和 RFC 正确地携带
CJK。参见
[Windows shell 与编码 FAQ](windows-shell-and-encoding-faq.md)。要在屏幕上*看到* CJK，
请用配了 CJK 字体的 Windows Terminal。

**我同时打开了两个客户。**
每个系统用一个 `claude` 对话，各自用 `/sap-login --switch <SID>` 固定。broker 会隔离
SAP 会话；按连接的设置让每个客户的 TR 策略 / 包 / 函数组彼此独立。

**我生成的文件去哪了？**
在 `{work_dir}\source_code\work\{doc_name}_{timestamp}\` 下。工作文件夹绝不会被自动
删除 —— 你可以在那里检查或手工编辑任何 `_*.txt` 和那个 `.abap`。

**我怎么看技能都做了什么？**
`/sap-log-analyze` 汇总 JSONL 运行日志（每个技能的计数、成功/失败率、p50/p95 时长、
top 错误类别）。

---

## 附录 A —— 完整技能目录

### sap-dev-core（基础 + ABAP 工作台）

| 技能 | 用途 |
|---|---|
| `sap-login` | 连接 + 多配置连接库（DPAPI 加密）、AI 会话固定 |
| `sap-dev-init` / `sap-dev-status` / `sap-dev-clean` | 引导 / 报告 / 拆除开发环境 |
| `sap-doctor` | 只读环境预检，每个失败配一条 FIX |
| `sap-transport-request` / `sap-se01` | TR 解析策略 / TR 的创建-释放-删除 |
| `sap-se38` / `sap-se37` / `sap-se24` / `sap-se11` / `sap-se91` | 部署 程序 / FM / 类 / DDIC / 消息类 |
| `sap-se21` / `sap-function-group` | 创建 / 检查 / 删除开发包 / 函数组 |
| `sap-se41` / `sap-se51` / `sap-se54` | PF 状态 / 屏幕 / 表维护对话 |
| `sap-se16n` | 查询任意表 → 制表符分隔下载 |
| `sap-se19` / `sap-cmod` | BAdI 实现 / 增强项目 |
| `sap-snro` | 编号范围对象 |
| `sap-activate-object` / `sap-change-package` / `sap-where-used-list` | 激活 / 移动包 / 交叉引用 |
| `sap-atc` / `sap-run-abap-unit` | ATC 门禁 / ABAP Unit 运行器 |
| `sap-transport-readiness` / `sap-impact-analysis` / `sap-enhancement-advisor` / `sap-evidence-pack` | 交付保障 |
| `sap-stms` | 把一个已释放的 TR 沿系统格局导入（生产受门禁） |
| `sap-diagnose` + `sap-st22` | 事故分诊（内置 SM13/SM12/SLG1/SM37 RFC 读取器，`--reader <name>` 单独运行）+ ST22 转储读取器 |
| `sap-sp02` | 显示 / 导出假脱机输出请求 |
| `sap-fix-incident` / `sap-check-fix` | 测试优先的修复闭环 / 检查并修复的路由器 |
| `sap-trace` | 分析一段已记录的性能追踪 |
| `sap-explain-object` / `sap-compare` | 理解（`--spec` 输出正式规格文档）/ 跨系统差异 |
| `sap-rfc-wrapper` | 通过 RFC 调用非 RFC 的 FM（`fm`）/ 封装类方法（`class`）|
| `sap-call-bdc` / `sap-update-addon` | BDC 重放 / 附加表维护 |
| `sap-gui-probe` / `sap-gui-inspect` / `sap-gui-skill-scaffold` | 技能编写 & GUI 健壮性工具（`--record` 为手动捕获；黄金屏幕漂移 → `/sap-doctor --screens`）|
| `sap-log-analyze` / `sap-error-kb` | 日志汇总 / 常见错误知识库 |

### sap-gen-code（规格 → ABAP）

| 技能 | 用途 |
|---|---|
| `sap-docs-layout` | 编辑规格工作簿布局 |
| `sap-docs-extract` | 文档 → 结构化 `_*.txt` 文件 |
| `sap-docs-convert` | 应用客户归一化规则 |
| `sap-docs-check` | 校验规格（DDIC + 处理逻辑维度） |
| `sap-gen-abap` | 生成 ABAP（报表 / 对话 / FM） |
| `sap-check-abap` / `sap-fix-abap` | 校验 / 自动修复 ABAP 质量 —— 命名、类型、SQL、CALL FUNCTION 签名、编译器语法 |

### sap-migrate（S/4HANA 自定义代码迁移）

`sap-cc-campaign`、`sap-cc-inventory`、`sap-cc-usage`、`sap-cc-analyze`、
`sap-cc-triage`（含 `--learn` 飞轮）、`sap-cc-remediate`、`sap-cc-decommission`。

### sap-tcd（业务事务）

`sap-bp`、`sap-mm01`、`sap-va01`。

---

## 附录 B —— 设置参考

跨多个层级解析（最高优先在前）：环境变量 `SAPDEV_AI_WORK_DIR`（仅 work_dir）→
`settings.local.json` → `{work_dir}\runtime\userconfig.json` → 插件 `settings.json`。
你很少需要手工编辑这些 —— 技能会写它们。关键的几项：

| 键 | 默认值 | 由谁设置 |
|---|---|---|
| `work_dir` | `C:\sap_dev_work` | 环境变量 / `/sap-login` 引导 |
| `way_to_get_transport_request` | `DEFAULT` | `/sap-dev-init` |
| `sap_dev_transport_request` | 空 | `/sap-dev-init`、`/sap-transport-request` |
| `sap_dev_package` | `ZCMDEVAI` | `/sap-dev-init` |
| `sap_dev_function_group` | `ZFGDEVAI` | `/sap-dev-init` |
| `rule_of_tr_description` / `tr_description_template` | `ASK` / 空 | `/sap-dev-init` |
| `sap_dev_mode` | `GUI` | 按连接 |
| `fm_cache_enabled` / `fm_cache_ttl_*_days` | `true` / 30 / 1 | userconfig |
| `log_*` | 见 CLAUDE.md | userconfig |

按连接的开发默认值（TR / 包 / 函数组 / 模式 / TR 策略）存放在
`connections.json[<id>].dev_defaults` 中，并按对话 × 连接隔离，因此并行工作永不破坏一个
共享默认值。

---

## 附录 C —— ABAP 命名与长度限制

生成器和检查器都强制执行这些；当你手工编辑时要心里有数。

| 对象 | 最大长度 | 约定 |
|---|---|---|
| `PARAMETERS` / `SELECT-OPTIONS` | **8**（含前缀） | `p_bukrs`、`s_matnr` |
| 变量 / 类 / 方法 / 局部类型 | **30** | `lv_…`、`ls_…`、`lt_…`、`gv_…`、`gc_…` |
| 函数模块 / 域 / 数据元素 / 表 / 结构 | 30 | `Z…` / `Y…` |
| 消息类 / 函数组 | 20 | `ZHKMSG01` / `ZHKFG01` |
| 程序 / 报表 | 40 | `ZHKMM001R01` |
| 全局类 / 异常类 | 30 | `ZCL_…` / `ZCX_…` |

变量前缀（`abap_naming_rules.tsv`，可按项目覆盖）：`lv_`/`ls_`/`lt_`
局部 变量/结构/表，`gv_`/`gs_`/`gt_` 全局，`gc_`/`lc_` 常量，`p_`
参数，`s_` 选择选项。

源代码约定：行保持 ≤ 72 列；规格中的注释/UI 文本用其自然语言；代码注释用
`MODE_COMMENT_LANG`（默认 = SAP 登录语言）。DDIC 定义文件使用**真正的 TAB** 字节。

---

*技能在不断演进 —— 拿不准时，每个技能的 SKILL.md 才是真相
之源，而 `/sap-doctor` 会告诉你环境是否就绪。问题反馈：
<https://github.com/sapdev-ai/sap-dev/issues> · <https://sapdev.ai>。*
