# macOS Apple Silicon 构建（GitHub Actions）

这个目录就是一个**可以直接推上 GitHub 的最小仓库**：workflow 会自己 clone Jan v0.8.8、打补丁、配夜间渠道、编引擎、出 `.app` + `.dmg`，并把它们作为构建产物上传。你不需要有 Mac。

## 内容
| 文件 | 作用 |
|---|---|
| `.github/workflows/jan-macos-arm64-patched.yml` | 在 `macos-14`（Apple Silicon runner）上构建 arm64 包 |
| `patch/configurable-cowork-token-budget.patch` | 产品代码补丁（token 预算 / 步数上限可配 + composer 上下文长度下拉 + 计费修复 + 测试） |
| `tools/mac-nightly-channel.mjs` | 夜间渠道与版本配置（带 `-` 的版本号才会启用 Cowork；productName/identifier/mainBinaryName；关闭自动更新；默认移除 MLX 资源） |

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
然后在 GitHub 上：**Actions → “Jan macOS arm64 (patched build)” → Run workflow**，参数默认即可：
- `jan_ref` = `v0.8.8`
- `version` = `0.8.8-5712`（必须带 `-`，否则 Cowork 不显示）
- `engine_variant` = `metal`（M 芯片本地推理；要纯 CPU 就选 `cpu`）

跑完在那次运行的 **Artifacts** 里下载：
- `jan-nightly-macos-arm64-patched` → 内含 `Jan-nightly_0.8.8-5712_aarch64.dmg` 与 `Jan-Desktop-nightly.app`

## 装到 Mac 上
包是**未签名**的（没有开发者证书）。首次打开：
```bash
xattr -dr com.apple.quarantine "/Applications/Jan-nightly.app"
```
或者右键 → 打开 → 再点「打开」。

## 注意
- MLX 后端默认不打进包（需要额外 `xcodebuild` 编 `mlx-server`）。llama.cpp + Metal 正常打包，本地 GGUF 推理可用；MLX 模型不会被列出。要带 MLX：在 workflow 里加一步 `make build-mlx-server`，并把渠道脚本改成 `--with-mlx`。
- 自动更新已关闭，官方 nightly 不会覆盖这个构建。
- 数据目录沿用 `Jan-nightly` 的标识（`jan-nightly.ai.app`），所以首次运行会读到该机器上已有 Jan-nightly 的 provider/模型/会话；如果那台 Mac 上装过官方 Jan-nightly，二者不要同时运行。
- 想同时出 Windows 包：用我给你的 `dist\...windows...exe`（本机已构建好），或把同样的步骤写一个 `windows-latest` job（注意 Windows 侧的 NSIS 附加插件路径与 `VIProductVersion` 需要两处修补，见上级目录 `README-patch.md`）。
