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

## 0.11.12 首包就绪修正

- 使用模拟采集器复现：`start()` 已返回但没有音频包时，旧版 `connect()` 会直接返回，随后提前显示绿色提示。新增回归在旧实现上失败。
- 修正后等待第一个非空 PCM 包并提交启动缓存后才返回。首包前取消、输入故障和 5 秒无回调超时均结束等待；松键结束等待后仍通过 consumer 排空尾包，界面不再闪现绿色。
- 新增 `First captured audio packet` 和 `Startup audio delivered` 调试节点。使用真实设备时应对比它们与 `AudioEngine started` 的时间差。
- 模拟检查不证明真实识别首字准确率。需要在 Apple 和豆包下分别验证：等绿后立即讲话、Cold/Warm 启动、快速松键以及首次权限等待。

## 0.11.13 蓝牙输入兼容验证

- 用户反馈：使用本机麦克风可正常开头，蓝牙麦克风在提示变绿后立即讲话仍吃字；0.11.12 首包判断没有解决蓝牙场景。
- 使用实际 input audio unit 对应的设备 transport 判断蓝牙类型，仅 Bluetooth / Bluetooth LE 增加 64,000 字节（1 秒 16 kHz Float32 mono）的准备窗口。累计的是收到的真实音频，不插入或丢弃 PCM。
- 模拟检查覆盖第一包后仍未就绪、到达窗口后完整提交前缀、准备期间松键仍提交短句；原先的首包、取消、超时和尾包检查继续保留。
- 1 秒是保守兼容窗口，不是系统提供的硬件就绪信号，也不是实测得到的通用延迟。需在用户的蓝牙耳机上验证冷/热启动和等绿后立即开口。
- 诊断用标准单声道 16 / 44.1 / 48 / 96 kHz 合成波形转换到 16 kHz 未复现开头消失；这不覆盖实际麦克风、蓝牙驱动或语音识别准确率。

## 0.11.14 半秒窗口对照测试

- 按用户要求将当前蓝牙输入门槛改为 32,000 字节，即 0.5 秒 16 kHz Float32 单声道音频。计时依据实际收到的音频长度，硬件启动和识别模型准备仍可能增加按键到变绿的时间。
- 回归检查在累计 0.4 秒时仍等待，累计 0.5 秒后才就绪，并核对所有前缀音频的顺序与字节内容；保留快速松键检查。
- 仍需用户在同一蓝牙耳机上测试等绿后立即讲话，比较第一句、连续使用和重连后的开头是否完整。

## 0.11.15 恢复一秒窗口

- 用户在 0.5 秒版本中仍遇到开头吃字，并明确要求恢复 1 秒；当前蓝牙门槛恢复为 64,000 字节。
- 回归检查在累计 0.9 秒时仍等待，达到 1 秒才就绪，核对前缀完整性和准备期间松键的短句提交。

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
