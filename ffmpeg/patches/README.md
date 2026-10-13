# patches — 来自 sggc/mpv-android-avs 仓库（同一维护者，已在真机验证）

这三个补丁解决 **Android/ExoPlayer(nextlib) 路径** 的 AVS2/AVS3 解码问题。
上游代码本身没问题，缺的是 Android 场景下的位深与稳定性支持。

## davs2-10bit.patch（davs2 1.7 验证可干净应用）
上游 davs2 默认只编 8bit。三处改动：
1. `build/linux/configure`：去掉 `--bit-depth=9/10` 的 exit 1 闸门
2. `source/common/decoder.cc`：零拷贝快路径的指针强转适配高位深
3. `source/common/osdep.h`：`ALIGN_POINTER` 改类型中性
   （frame.cc 里两种指针类型都用这个宏，写死任一指针对都错）
→ setup.sh 同时传 `--bit-depth=10`。现网 IPTV 的 AVS2 直播大量是 10bit
（山东/CCTV 4K 频道），不修则报 `Un-supported bit-depth 10 in this version.`。

## davs2-flush-crash.patch（davs2 1.7 验证可干净应用）
`davs2_decoder_flush()` 会强制解码缓冲区里"还没被下一个起始码封口"的 AU，
参考帧/比特流状态不一致 → `add_ps[]` 越界读 → SIGSEGV。
上游 master 也没改。修复：把强制解码改为**丢弃**（flush 语义本就是放弃当前位置）。
→ seek 时 FFmpeg 的 libdavs2 wrapper 会调 davs2_decoder_flush，不修则
   拖进度条有概率直接闪退（mpv 路径 2026-10-13 真机复现并 A/B 证实）。

## uavs3d-10bit.patch（对 uavs3d master 验证可干净应用）
`source/decore/com_def.h`：`COMPILE_10BIT` 默认 0→1。
→ setup.sh 的 cmake 同时传 `-DCOMPILE_10BIT=1`（头文件有 #ifndef 保护，双保险）。

## 注意
- **不需要** davs2-seek-deadlock.patch：davs2 **1.7 已自带**该修复
  （`task_get_references` 失败分支已有 `unlock`，见 davs2.cc 的 else 分支），
  但 1.6 分支没有。nextlib 用 1.7，故只带上面三个。
- 应用方式：`git apply --check` 先行，失败即 `exit 1`（不静默跳过 —— 上游
  源码变动时必须让 CI 明确失败，而不是产出一个缺东西的库）。
