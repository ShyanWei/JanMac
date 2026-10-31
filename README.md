# macOS Apple Silicon 构建（GitHub Actions）

这个目录是一个**可以直接推上 GitHub 的最小仓库**：workflow 自己 clone Jan v0.8.8、打补丁、配夜间渠道、编引擎、出 `.app` + `.dmg`，并把它们作为构建产物上传。你不需要有 Mac。

## 内容
| 文件 | 作用 |
|---|---|
| `.github/workflows/jan-macos-arm64-patched.yml` | 在 macOS Apple Silicon runner（`macos-15`/`26`）上构建 arm64 包 |
| `patch/configurable-cowork-token-budget.patch` | 产品代码补丁（token 预算 / 步数上限可配 + composer 上下文长度下拉 + 计费修复 + 测试，16 个文件） |
| `tools/mac-nightly-channel.mjs` | 夜间渠道与版本配置（带 `-` 的版本号才会启用 Cowork；productName/identifier/mainBinaryName/Info.plist；关闭自动更新与更新产物；默认移除 MLX 资源） |
| `tools/mac-engine-toolchain.sh` | 挑一个能编译 ggml `apple_m4` 变体的 Xcode，必要时改 vendored cmake（见下） |
| `tools/adhoc-sign-mac-bundle.sh` | 给未签名的 `.app` 做 ad-hoc 签名并重写 `.dmg`，避免 macOS 报「已损坏」（见下） |
| `tools/build-mac-nightly.sh` | 有 Mac 时的一键本地构建（同一套补丁与渠道配置） |

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
然后 GitHub 上：**Actions → “Jan macOS arm64 (patched build)” → Run workflow**，默认参数即可：
- `jan_ref` = `v0.8.8`
- `version` = `0.8.8-5712`（**必须带 `-`**，否则 Cowork 不显示；workflow 里有专门的快速校验）
- `runner` = `macos-15`（Apple Silicon；arm64 runner 排队可能较慢，可选 `macos-26`。**已去掉 `macos-14`**：GitHub 的 macOS 14 镜像 2026-11-02 起不再支持，而且它默认的 Xcode 15.4 正是编不出 `apple_m4` 的那套 flags）
- `engine_variant` = `metal`（M 芯片本地推理；纯 CPU 选 `cpu`）
- `xcode` = 留空 = 自动挑一个能编译引擎的 Xcode（必要时给 vendored cmake 补 `+sve`）；也可填具体版本，如 `16.4`、`26.3`

跑完在那次运行的 **Artifacts** 里下载 `jan-nightly-macos-arm64-patched`，内含
`Jan-nightly_0.8.8-5712_aarch64.dmg` 与 `Jan-Desktop-nightly.app`。

## 推不动时（DNS 把 github.com 解析成空）
`git push` 报 `Failed to connect to github.com port 443`，但浏览器能打开 GitHub（浏览器走了加密 DNS）。确认：
```powershell
Resolve-DnsName github.com -Type A    # 空 = 解析被过滤
Test-NetConnection github.com -Port 443   # False
```
`api.github.com` 是通的，说明只有 `github.com` 的解析被拦。两种办法：
1. 等解析恢复后重试 `git push origin main`。
2. 用**管理员** PowerShell 加一条 hosts（GitHub IP 直连是通的，证书对 `github.com` 有效）：
```powershell
Add-Content -Path "$env:WINDIR\System32\drivers\etc\hosts" -Value "140.82.114.4 github.com"
ipconfig /flushdns
cd D:\AgentProjects\JanFix\mac-ci
git push origin main
# 推完删掉这行，否则以后 IP 轮换反而连不上
(Get-Content "$env:WINDIR\System32\drivers\etc\hosts") -notmatch 'github\.com' | Set-Content "$env:WINDIR\System32\drivers\etc\hosts"
```

## 装到 Mac 上
包是**未签名**的（没有开发者证书、也没公证）。打开 dmg，把 `Jan-nightly.app` 拖进「应用程序」；首次打开要告诉 Gatekeeper 别拦：
```bash
xattr -cr "/Applications/Jan-nightly.app"        # 清掉隔离属性
```
或者右键 → 打开 → 再点「打开」。

### 如果报「已损坏，无法打开」
这不是下载坏了，而是 Tauri 在没有 Developer ID 时**根本不给 bundle 签名**：`Contents/_CodeSignature` 不存在，但里面的 `libggml*.dylib` / `libggml-*.so` / `bun` / `uv` 带着链接器自带的 ad-hoc 签名（`flags=0x20002(adhoc,linker-signed)`）。这种「内层有签名、外层没封条」的半签名 bundle，`codesign --verify --deep --strict` 会报 `code has no resources but signature indicates they must be present`，macOS 15/26 对带隔离属性的它就显示成「已损坏」。

CI 里的 `tools/adhoc-sign-mac-bundle.sh` 已经处理：先给所有内层 Mach-O 做 ad-hoc 签名、再给 `.app` 本身签名，然后用签名后的 app 重写 dmg（tauri 是先出 dmg 的，事后签名不会被带进去）。已经下载的旧包本机修一次即可：
```bash
APP=/Applications/Jan-nightly.app          # 或 下载/.../macos/Jan-nightly.app
find "$APP" -type f -print0 | xargs -0 file -b | grep -c Mach-O   # 先看有多少 Mach-O
find "$APP" -type f -print0 | while IFS= read -r -d '' f; do
  file "$f" | grep -q 'Mach-O' && codesign --force --sign - "$f"
done
codesign --force --sign - "$APP" && codesign --verify --deep --strict "$APP" && xattr -cr "$APP"
```

## 失败了怎么看
1. 打开那次运行 → `build` job → 找红色的步骤（步骤名已经能定位阶段：`Apply the patch` / `Nightly channel + version` / `Build the engine` / `Build the app and the dmg`）。
2. 右上角 **View raw logs**（zip）或点开该步骤看完整输出；把那段贴给我即可。
3. 失败时 workflow 会额外上传 `build-diagnostics` 产物，里面有 `src-tauri/target/engine-build.log`（cmake 的完整输出，cargo 只在失败时才打印 build script 输出，所以引擎失败主要看这个日志）。

## 这一版修掉的问题
- **装上去报「已损坏，无法打开」**：Tauri 在没有 Developer ID 时不签 bundle（`Contents/_CodeSignature` 缺失），而内层 Mach-O 有链接器的 ad-hoc 签名 —— 半签名 bundle 在 macOS 15/26 + 隔离属性下就表现为「damaged」。新增 `tools/adhoc-sign-mac-bundle.sh`，在 `tauri build` 之后把所有内层 Mach-O 和 bundle 本身 ad-hoc 签好，再用签好的 app 重写 dmg。本机用你下载的产物实测：`codesign --verify --deep --strict` 从失败变成 `valid on disk` / `satisfies its Designated Requirement`，重写后的 dmg 可挂载、内含 `Applications` 快捷方式与 12 个引擎文件，装到 `/Applications` 后能正常启动并拉起 `jan-llama-worker`。仍然是 ad-hoc 签名，所以首次打开还是要 `xattr -cr` 或右键打开 —— 只是不再被当成损坏文件。
- **`Engine toolchain` 步骤自己挂了**（第三次运行）：
  ```
  engine toolchain: current toolchain cannot compile 'svexpa_f32' with -march=armv9.2-a+dotprod+i8mm+nosve+sme
  engine toolchain: no installed Xcode compiles it; patching the vendored cmake
  error: even without '+nosve' this toolchain rejects svexpa_f32.
  ```
  这段并不是工具链的问题，而是 `mac-engine-toolchain.sh` 的探测代码写错了：它把 `svexpa_f32` 当作接收 `svfloat32_t` 的函数来调用（真实签名是 `svexpa_f32(svuint32_t)`），并且在没有 SVE/streaming 标注的普通函数里直接使用 SVE 类型。结果这套探测在**任何**工具链上都失败 —— 连能正常编译引擎的 Xcode 21 也会报 `no matching function for call to 'svexpa_f32'` / `SVE vector type ... cannot be used in a non-streaming function`。于是「换 Xcode」永远找不到候选，cmake 补好之后最后一步又判定失败，job 直接 exit 1。现在探测改成复刻 `vec.h` 里真正出问题的那个构造（`#if defined(__ARM_FEATURE_SVE)` + 非 streaming 函数里 `svexpa_f32(svuint32_t)`），并在每一步打印编译器真实的 error 行。本机 Xcode 26.6 / Apple clang 21 实测：upstream flags 通过，`+sve` 版本也通过；用模拟的 AppleClang-15 行为（`+nosve` 失败、`+sve` 通过）走的是打补丁分支并 exit 0。
- **引擎编译失败**（第二次运行，挂在 `Build the engine`，95% 处）：
  ```
  ggml/src/ggml-cpu/vec.h:1100:26: error: 'svexpa_f32' needs target feature sve
  ```
  ggml 的 `apple_m4` CPU 变体（`ggml/src/CMakeLists.txt` 里 `apple_m4 DOTPROD MATMUL_INT8 NOSVE SME`）用 `-march=armv9.2-a+dotprod+i8mm+nosve+sme` 编译，而 `vec.h` 的 `exp_ps_sve()` 里调用了 SVE intrinsic `svexpa_f32`。AppleClang 15（Xcode 15.4，macos-14 镜像默认）因为 `+sme` 而定义 `__ARM_FEATURE_SVE`，但 `+nosve` 又把目标特性关掉，于是那段代码被编译并报上面的错；较新的 AppleClang 会正确处理 `+nosve`（Jan 官方发布 CI 固定用 Xcode 26.x，就是这个原因）。`tools/mac-engine-toolchain.sh` 现在按代价从低到高四级降级：① 当前工具链能编 upstream flags 就不动；② 否则从新到旧试镜像里已安装的 Xcode，选第一个能编的并切过去（都不行就恢复镜像原来的 `xcode-select`）；③ 把 **vendored** ggml cmake 里的 `+nosve` 换成 `+sve`（`armv9.2-a` 本身带 SVE2，而该模块只在运行时检测到 SME 的机器上才被选用，即 M4+，这类机器必然有 SVE；dispatch 逻辑与其他变体不动）；④ 连 `+sve` 都编不了（说明这个工具链根本不支持 SVE/SME intrinsic），就把 `apple_m4` 变体从 vendored cmake 里删掉并把 ③ 改回去，构建仍然能完成，包里只是没有 `ggml-cpu-apple_m4` 模块（M4+ 上 CPU 回落到 `ggml-cpu-apple_m2_m3`，Metal 不受影响）。可选参数 `xcode` 可直接指定版本。
- **runner 默认值**：`macos-14` → `macos-15`。GitHub 的 macOS 14 镜像 2026-07-06 起进入弃用、2026-11-02 完全不再支持，而它的默认 Xcode 15.4 正是编不出 `apple_m4` 的那套 flags。`macos-15` 默认 Xcode 16.4，镜像里还装了 26.0~26.3，脚本会自动挑能编译的那个；`macos-26` 默认 Xcode 26.6（Apple clang 21，upstream flags 直接通过）。
- **v1 的硬失败**：`cp tools/mac-nightly-channel.mjs tools/...` —— Jan 仓库根目录**没有 `tools/`**，`cp` 直接报错，job 在几分钟内就挂了。现在按绝对路径运行脚本，不再往 jan 里复制。
- `Info.plist` 之前没改（官方 nightly 会改）：bundle id 与 URL scheme 仍是 `jan.ai.app`。渠道脚本现在把它改成 `jan-nightly.ai.app` / `jan-nightly`。
- 显式 `bundle.createUpdaterArtifacts = false` + `plugins.updater.active = false`：未签名构建如果要求产出更新产物，打包会因为缺 `TAURI_SIGNING_PRIVATE_KEY` 中止。
- MLX 资源必须从 `tauri.macos.conf.json` 的 `bundle.resources` 里删除（不是运行时跳过就行）：tauri 的 build script 会对声明了但不存在的资源路径直接失败。脚本已删并把数量打印出来。
- 新增：`cmake` 缺失时自动 `brew install`；`yarn config set -H enableImmutableInstalls false`（与上游 CI 一致）；`timeout-minutes: 120`；arm64 runner 可选；失败时上传诊断。

## 注意
- MLX 后端不打进包（编译 `mlx-server` 需要额外的 `xcodebuild` + mlx-swift）。llama.cpp + Metal 正常打包，本地 GGUF 推理可用；MLX 模型不会被列出。要带 MLX：渠道脚本加 `--with-mlx`，并在 workflow 里加一步 `make build-mlx-server`。
- 数据目录沿用 nightly 标识（`jan-nightly.ai.app`），首次运行会读到该机器上已有 Jan-nightly 的 provider/模型/会话；若那台 Mac 装过官方 Jan-nightly，二者不要同时运行。
- Windows 包已在本机构建好：`D:\AgentProjects\JanFix\dist\Jan-nightly_0.8.8-5712_patched-win_x64-setup.exe`。Windows 侧的 CI 化还需要 NSIS 模板的两处修补（附加插件路径、`VIProductVersion` 占位符），需要的话我再给你加一个 `windows-latest` job。
