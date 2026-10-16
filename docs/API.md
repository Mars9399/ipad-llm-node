# API

所有路由要求 `Authorization: Bearer <本地令牌>`。默认端口 8080；USB 转发示例端口为 Mac 18080。

## 推理

- `GET /health`：ready、busy、实际模型/revision、MLX 分配、phys_footprint、物理内存、额外进程预算、温度压力及计数。
- `GET /v1/models`：当前激活模型与量化信息。
- `POST /v1/chat/completions`：文本 Chat Completions。

```json
{"model":"mlx-community/Qwen3-4B-4bit","messages":[{"role":"user","content":"你好"}],"max_tokens":128,"temperature":0,"seed":42,"stream":true,"stream_options":{"include_usage":true}}
```

顶层仅支持 model、messages、max_tokens 或 max_completion_tokens、temperature、seed、stream、stream_options.include_usage。model 可省略，省略时使用激活模型；不能通过单个聊天请求自动切换模型。

消息为非空字符串，1–32 条，system 只能在开头，末条为 user。模板处理后输入最多 2048 token、输出 1–512 token，缺省 256；temperature 0–2，缺省 0；seed 为 UInt64。消息正文合计 32KiB，请求正文 64KiB。没有推理等待队列，一个 GPU 任务正在执行时返回 429。

普通响应含 choices、usage、device_metrics。SSE 依次输出 role、content、完成原因、独立 usage（缺省开启）、[DONE]；完成块也含 device_metrics。接收方必须检查流中的 error 及结束标志。关闭连接会取消推理并等待清理。

设备 TTFT 从输入准备开始到消费首个原始 token 事件，包括分词、prefill 和此期间服务工作；Mac 首内容延迟包含网络与缓冲，两者定义不同。decode_tokens_per_second 排除首 token，按消费 token 的时间戳计算，可能受文本解码与网络背压影响；输出不足 2 token 时为 0。usage 核对原始计数与库完成计数，不按文字片段计数。

MLX Swift LM 3.31.3 达到输出上限时可能在原始元数据中报告 cancelled；本服务按实际达到上限返回 length，同时保留 library_stop_reason。温度压力枚举不是摄氏度，MLX 内存与进程 footprint 不可相加。process_available_bytes 是动态额外进程预算，不是空闲物理内存。

生成任务返回后开始 120 秒合作式取消计时，不是包括此前准备/prefill 的端到端硬期限。传输层另有 15 秒请求读取和单次写入超时，最多 8 个连接，一个连接只处理一个请求。

## 模型管理

- `GET /v1/node/models`：精选目录、revision、安装/选择状态、下载任务、进度及说明。
- `POST /v1/node/models/download`，正文 `{"model":"目录中的ID"}`：开始下载，202 表示接受任务；轮询目录判断校验完成，不代表下载已完成。
- `POST /v1/node/models/cancel`，正文 `{}`：取消当前下载；等待 downloading_model 为 null 后才能开始下一项。
- `POST /v1/node/models/activate`，正文 `{"model":"已安装模型ID"}`：接受切换，202 后监听可能短暂不可用；等待 health 的 ready=true 且 model 为目标 ID。模型切换会取消当前推理。
- `POST /v1/node/models/delete`，正文 `{"model":"非当前模型ID"}`：删除对应下载目录及缓存。已有预装 4B 文件保留。

目录是受限模型列表，不接受任意 URL、仓库或 GGUF。下载与切换互斥；模型切换中的聊天不可用。下载失败不会替换现有模型；新模型加载失败时尝试恢复上一模型。进度到 100% 后仍需等待文件校验。

常见返回码：400 不合法参数/管理操作，401 鉴权，404 路由，409 模型操作冲突，413 正文超限，415 类型错误，429 推理忙碌，500 推理失败，503 未就绪/取消，504 生成超时。SSE 开始后的失败使用 error 事件。

下载状态另含 downloaded_bytes、total_download_bytes，各模型含 saved_bytes。只有 installed=true 才可激活；文件字节达到 100% 后仍需完整校验。下载中断后 .partial 文件保留，后续操作通过 HTTP Range 继续。
