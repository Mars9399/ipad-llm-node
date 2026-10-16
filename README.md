# iPad LLM Node

让 Apple Silicon iPad 在本地运行量化 Qwen3，并通过 USB 或局域网供 Mac 调用。基于 Apple 的 [MLX Swift Examples](https://github.com/ml-explore/mlx-swift-examples)，保留原始 MIT 许可及上游示例；主要修改在 `Applications/LLMEval`。

## 功能

- iPad 内直接下载模型，显示进度，支持取消、重试、已完成文件缓存复用及删除下载。
- 固定模型 revision 和文件大小，下载完成后校验 LFS 文件 SHA-256 与配置的 Git blob 指纹，再标记为已安装。
- 模型独立存储于 Application Support；只有一个模型常驻内存。切换前取消并等待推理退出，释放旧模型；新模型加载失败时恢复上一模型。
- 模型选择在重启后保留。已有 `Documents/model` 的已验证 4B 安装可继续使用。
- Bearer 鉴权 HTTP API，支持普通文本回复与 SSE、真实 token 计数、首 token、内存及温度压力指标。

模型目录包括 Qwen3 4B 4bit、官方 8B 4bit、8B 3bit，以及用于快速验证下载的 0.6B 4bit。下载这些公共模型无需填写外部 API Key。8B 提供下载入口，并不意味着已在所有 iPad 上验证性能与内存。

“加载”按钮始终显示；未下载完整、校验中或其他模型操作进行时会灰显，并说明原因。百分比同时显示实际字节容量；100% 字节不等于已通过校验。

App 需要在前台运行。切到后台会取消下载和推理、暂停服务；返回前台可重新下载或恢复服务。部分文件保存在模型目录，重试会发起 HTTP Range 续传；模型源忽略 Range 时会安全重新下载，避免重复追加。旧版残留的权重临时文件仅在匹配固定版本的前缀指纹后恢复，最终仍须通过完整 SHA-256。这里不保证锁屏后台下载。

## 编译与运行

已使用 Xcode 27.1、iPadOS 27.0.1、M1 iPad Pro 验证。工程的 LLMEval 部署目标为 iPadOS/iOS 26.5。模型推理使用真实设备的 Metal，不以模拟器作为 GPU 性能依据。

```sh
git clone https://github.com/Mars9399/ipad-llm-node.git
cd ipad-llm-node
open mlx-swift-examples.xcodeproj
```

在 Xcode 选择 `LLMEval` scheme、自己的开发团队与唯一 Bundle ID，连接已信任且开启开发者模式的 iPad。确认固定依赖的宏信任提示，安装所需 Metal Toolchain 后运行。

关键依赖固定为 MLX Swift LM **3.31.3** 和 MLX Swift **0.31.4**；工程使用公开远程依赖，包含已解析的 Package.resolved，不需要本机旁边另有 Swift LM 仓库。

首次进入“模型管理”，下载 4B 或较小的 0.6B，完成后点击“加载”。公开仓库不含模型权重、签名证书、设备 ID 或访问凭据。开发签名有效期由自己的 Apple 账号与描述文件决定。

也可使用环境变量运行编译安装脚本：

```sh
export IPAD_DEVICE_ID='你的设备标识'
export DEVELOPMENT_TEAM='你的开发团队'
export BUNDLE_ID='你的唯一BundleID'
./Scripts/deploy.sh
```

## Mac 调用

iPad 顶部可复制本地服务令牌，并显示局域网地址。USB 使用 libusbmuxd 提供的 `iproxy` 转发：

```sh
iproxy -u "$IPAD_DEVICE_ID" -s 127.0.0.1 18080:8080
```

保持转发终端运行。将从 iPad 复制的本地服务令牌保存到 `.local/ipad-api-token.txt`，权限设为 600；此路径被 Git 忽略。使用部署脚本时会在本机生成并同步此令牌。

```sh
python3 Scripts/ipad-api-client.py health
python3 Scripts/ipad-api-client.py models
python3 Scripts/ipad-api-client.py chat '用中文介绍统一内存。' --stream --max-tokens 128
```

指定网络地址用 `--endpoint http://<iPad地址>:8080`，放在子命令前；调用其他已激活模型时，chat 增加 `--model <模型ID>`。当前默认客户端仍使用 4B。服务是 OpenAI 风格 Chat Completions 的文本子集，不支持工具、图像或任意额外参数。详见 [API 文档](docs/API.md)。

监听 iPad 的 TCP 8080，采用 Bearer 和普通 HTTP，面向本机 USB 或可信局域网；未配置 TLS 或公网部署。

## 验证范围

测试记录见 [VALIDATION.md](docs/VALIDATION.md)。4B 已做约 20 分钟真机持续测试；不同输入长度的短测不是持续性能替代。0.6B 用于验证完整的下载和模型生命周期。更大模型的性能需另行实测。

项目来源与上游完整说明保存在 [README.upstream.md](README.upstream.md)。模型权重遵循各自仓库许可；精选目录使用 Apache-2.0 模型，本仓库不重新分发权重。
