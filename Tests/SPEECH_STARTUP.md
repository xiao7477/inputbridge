# 语音启动优化验证

## 实现约束

- Cold：识别缓存已释放。Warm：保留 Apple 模型所有权、已检查的语言/资源/格式及准备好的下一次 Analyzer；不保留音频采集、转换任务或结果监听。Recording：用户确认的听写会话。
- 默认在听写完成后空闲 300 秒释放，每次使用取消旧期限；配置变化、休眠、内存压力、识别错误会提前失效。立即释放模式不会准备下一次 Analyzer。
- 使用 `.whileInUse`，移除 `.processLifetime`。Apple 的 [模型保留文档](https://developer.apple.com/documentation/speech/speechanalyzer/options/modelretention-swift.enum/whileinuse) 说明该策略在 Analyzer 销毁时释放模型。
- 每次会话使用独立的结果流，收尾等待最终结果后，在旧 Analyzer 仍持有模型期间准备下一次 Analyzer；后续 Warm 启动跳过模型选择、AssetInventory、格式查询、Context 设置和 prepareToAnalyze。Warm 没有持续消费音频的任务。
- 本机与远程共用 16 kHz Float32 单声道采集入口。单修饰键确认由 220 ms 改为 100 ms。已有麦克风授权时，原生事件和兼容检测允许按键后预采集，组合键取消时不提交任何音频。未授权时等确认听写后才申请权限，避免普通组合键弹出权限对话框。硬件启动前、首次授权对话框期间无法缓存声音。
- 未确认时采用 500 ms 有界缓存；确认后启动缓冲最多 5 秒，保持开头和包顺序。模型下载或网络准备过慢时明确失败并关闭麦克风。松键先同步关闭麦克风，再排空尾包、完成识别。

## 自动验证

```sh
zsh Scripts/test-speech-startup.sh
zsh Scripts/test-speech-startup.sh --apple
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.2.sdk zsh Scripts/test-transport.sh
zsh Scripts/package.sh --local-only
```

启动回归测试使用替身，不打开麦克风、不调用云端识别，覆盖缓存逐字节顺序和上限、准备中松键、组合键取消、Cold/Warm 复用、空闲期限重置和迟到期限、立即释放、始终就绪、配置与错误失效。

可选的 `--apple` 集成检查仅使用已安装模型和合成静音，检查两次真实 Analyzer 会话与释放；模型未安装或语音服务不可访问时会报告跳过，不下载资源、不录音。沙箱可能无法枚举语言，需要在正常本机终端执行。

## 启动耗时实测

```sh
zsh Scripts/package.sh --local-only --debug
log stream --level debug --predicate 'subsystem == "com.inputbridge.macos" AND category == "SpeechLatency"'
```

退出旧 App 后运行生成的 `dist/语音输入共享.app`。临时签名发生变化时可能需要重新授权。调试日志按随机会话 ID 记录系统单调时钟的累计毫秒数，包含 Hotkey received、PTT confirmed、Route resolved、Cold/Warm、Speech assets ready、Analyzer preparation started/prepared/ready、Speech Engine ready、AudioEngine started、First audio buffer 和 First partial transcript。音频准备与识别并行，日志行不保证按阶段名称排序；日志不含音频、识别文字或密钥。发行构建不记录这些埋点。

分别测首次 Cold、连续三次 Warm、超过 5 分钟后的 Cold；对比快捷键确认、麦克风首缓冲、Analyzer 就绪和首个临时结果。不要把自动测试耗时或未实测的估计值当作改善幅度。

## 待真实设备验收

- 按键同时开口，确认中文/英文首字完整；Cold、Warm、本机、远程分别测试。
- 首次权限未授权、模型未下载、麦克风断开、豆包连接失败回退 Apple。
- Fn / Option / Control / Shift 加其他键，特别是 100 ms 内按下、先放开字符键后仍按住修饰键，不应重新启动语音。
- 准备期间快速松键、Esc、焦点切换、远端断开，不再采集；已经缓存的短句正常完成或明确取消。
- 结束后确认系统麦克风指示消失；Warm 数分钟观察 CPU、能耗与内存，空闲释放后比较内存。包含设置窗口打开、关闭和系统休眠唤醒。
- “始终保持就绪”待机时仍没有麦克风采集；“立即释放”下一次确实走 Cold。

这些自动测试和构建检查不代替实机延迟、识别准确性与后台能耗测量。

## 本次执行记录（2026-10-16）

- 启动生命周期 / 音频会话替身测试通过，包含准备中松键、缓冲排空时实时音频不超车、迟到空闲期限和异常释放。
- ShortcutMatcherSmoke、AudioPipelineSmoke 通过；Fn / Option / Control / Shift 覆盖普通打字后的首次触发、组合键字符先松开及确认前快速松键。修复普通打字将下一次单修饰键手势误标记为组合键的问题。
- 本机回环传输测试在原固定端口 54839 / 54840 报监听失败；保留原测试内容，仅在临时副本改用 54917 / 54918 后完整通过，覆盖双操作端、重建连接、音频尾包、拒绝原因及完成回执。
- 完整 arm64 优化构建与代码签名校验通过。
- 在正常本机权限下可枚举 43 个 Dictation、30 个 Speech 语言；中文和英文模型状态为 supported，尚未 installed。真实 Analyzer 集成检查明确跳过，没有下载模型或录音。
- 尚未得出真实启动毫秒数、首字准确性或 Warm 待机 CPU / 能耗改善结论。
