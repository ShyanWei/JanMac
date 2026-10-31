# macOS Apple Silicon 构建（GitHub Actions）

这个目录是一个**可以直接推上 GitHub 的最小仓库**：workflow 自己 clone Jan v0.8.8、打补丁、配夜间渠道、编引擎、出 `.app` + `.dmg`，并把它们作为构建产物上传。你不需要有 Mac。

## 内容
| 文件 | 作用 |
|---|---|
| `.github/workflows/jan-macos-arm64-patched.yml` | 在 macOS Apple Silicon runner（`macos-14`/`15`/`26`）上构建 arm64 包 |
| `patch/configurable-cowork-token-budget.patch` | 产品代码补丁（token 预算 / 步数上限可配 + composer 上下文长度下拉 + 计费修复 + 测试，16 个文件） |
| `tools/mac-nightly-channel.mjs` | 夜间渠道与版本配置（带 `-` 的版本号才会启用 Cowork；productName/identifier/mainBinaryName/Info.plist；关闭自动更新与更新产物；默认移除 MLX 资源） |

## 推上去并触发
```bash
cd mac-ci
git init -b main
git add .
git commit -m "Jan v0.8.8 patched build (macOS arm64)"
# 在你自己的 GitHub 账号下建一个空仓库，然后：
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```
GitHub 上：**Actions → “Jan macOS arm64 (patched build)” → Run workflow**，默认参数即可：
- `jan_ref` = `v0.8.8`
- `version` = `0.8.8-5712`（**必须带 `-`**，否则 Cowork 不显示；workflow 里有专门的快速校验）
- `runner` = `macos-14`（Apple Silicon；arm64 runner 排队可能较慢，可以选 `macos-15`）
- `engine_variant` = `metal`（M 芯片本地推理；纯 CPU 选 `cpu`）
- `xcode` = 留空用镜像默认；Metal 编译失败时可填具体版本（如 `16.4`）

跑完在那次运行的 **Artifacts** 里下载 `jan-nightly-macos-arm64-patched`，内含
`Jan-nightly_0.8.8-5712_aarch64.dmg` 与 `Jan-Desktop-nightly.app`。

## 装到 Mac 上
包是**未签名**的（没有开发者证书）。首次打开：
```bash
xattr -dr com.apple.quarantine "/Applications/Jan-nightly.app"
```
或者右键 → 打开 → 再点「打开」。

## 失败了怎么看
1. 打开那次运行 → `build` job → 找红色的步骤（步骤名已经能定位阶段：`Apply the patch` / `Nightly channel + version` / `Build the engine` / `Build the app and the dmg`）。
2. 右上角 **View raw logs**（zip）或点开该步骤看完整输出；把那段贴给我即可。
3. 失败时 workflow 会额外上传 `build-diagnostics` 产物，里面有 `src-tauri/target/engine-build.log`（cmake 的完整输出，cargo 只在失败时才打印 build script 输出，所以引擎失败主要看这个日志）。

## 这一版修掉的问题
- **v1 的硬失败**：`cp tools/mac-nightly-channel.mjs tools/...` —— Jan 仓库根目录**没有 `tools/`**，`cp` 直接报错，job 在几分钟内就挂了。现在按绝对路径运行脚本，不再往 jan 里复制。
- `Info.plist` 之前没改（官方 nightly 会改）：bundle id 与 URL scheme 仍是 `jan.ai.app`。渠道脚本现在把它改成 `jan-nightly.ai.app` / `jan-nightly`。
- 显式 `bundle.createUpdaterArtifacts = false` + `plugins.updater.active = false`：未签名构建如果要求产出更新产物，打包会因为缺 `TAURI_SIGNING_PRIVATE_KEY` 中止。
- MLX 资源必须从 `tauri.macos.conf.json` 的 `bundle.resources` 里删除（不是运行时跳过就行）：tauri 的 build script 会对声明了但不存在的资源路径直接失败。脚本已删并把数量打印出来。
- 新增：`cmake` 缺失时自动 `brew install`；`yarn config set -H enableImmutableInstalls false`（与上游 CI 一致）；`timeout-minutes: 120`；arm64 runner 可选；失败时上传诊断。

## 注意
- MLX 后端不打进包（编译 `mlx-server` 需要额外的 `xcodebuild` + mlx-swift）。llama.cpp + Metal 正常打包，本地 GGUF 推理可用；MLX 模型不会被列出。要带 MLX：渠道脚本加 `--with-mlx`，并在 workflow 里加一步 `make build-mlx-server`。
- 数据目录沿用 nightly 标识（`jan-nightly.ai.app`），首次运行会读到该机器上已有 Jan-nightly 的 provider/模型/会话；若那台 Mac 装过官方 Jan-nightly，二者不要同时运行。
- Windows 包已在本机构建好：`D:\AgentProjects\JanFix\dist\Jan-nightly_0.8.8-5712_patched-win_x64-setup.exe`。Windows 侧的 CI 化还需要 NSIS 模板的两处修补（附加插件路径、`VIProductVersion` 占位符），需要的话我再给你加一个 `windows-latest` job。
