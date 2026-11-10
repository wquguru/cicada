# aec-lab：用 WebRTC AEC3 代替系统回声消除的试验台

目的：同声传译按住说话时要消掉扬声器里的会议声。系统的回声消除（VoiceProcessingIO）只要存在，其他应用从内置麦克风就几乎收不到声音（#24），新建一次要 1.2–1.7 秒。这里试 AEC3（webrtc-audio-processing 2.1，BSD）：普通麦克风加知了自己录的系统声音做参考。只是试验，不进 App。

## 准备

- `brew install meson ninja`；`zsh build-aec.sh` 第一次会跑 `build-apm.sh`（下载、核对 SHA-256、编静态库到 `~/.cache/cicada-aec-lab`），再编 `aec`、`rec`、`transcribe`。
- 开发版要带 `aecDump:<秒>` 调试命令（`EchoDump.swift`：同时录系统声音和普通麦克风，带 host time，写到 `/tmp/cicada-aec-*`）。
- 录音前先确认没有别的进程握着系统回声消除：别的应用测内置麦克风会掉到 −40 dB 以下（只开一个开发版）。

## 工具

- `aec <采样率> <ref> <mic> <out>`：s16 单声道 raw。`TUNE=1..3` 放松抑制器；`LINEAR=1` 另写线性滤波输出（只能 16 kHz）和混合输出 `.hyb16.raw`（默认用抑制后的输出，收敛后在仍有人声的帧附近换成线性输出；`HYB_DB` `HYB_HOLD` `HYB_ERLE`）；`PER_SEC=1` 每秒 ERLE。
- `rec <秒> <wav> [vpio]`：录 MacBook Pro 麦克风（按名字固定），`vpio` 走系统回声消除作对照。
- `phone.py serve` / `play <wav> [--at <unix 秒>]`：iPhone 当会议室里的人。Mac 上起服务，iPhone Safari 打开 `http://<Mac IP>:8765` 点“开始”，页面保持前台；放在 Esc 旁扬声器格栅 10 cm 左右、音量最大。
- 打分：`transcribe`（本机识别）只作参考；决定用的是 Ming 听到的，`ming.sh <repo> <wav...>` 走真实按键流水线（`lsctl speakFile:`），要临时在 `SpeakEngine` 记下 Ming 的原文（不要提交）。

## 轮次

- `round.sh <repo> <音量>`：只有会议声：普通麦克风、VPIO、AEC3（16/48 kHz，参考提前多少）漏出的英文词。
- `gate3.sh <repo> <音量>`：用 App 自己的系统声音（`aecDump`），只按 host time 对齐。
- `dt.sh [record]`、`tune.sh`：离线叠加的双讲（近端从 Mac 扬声器录，偏悲观）。
- `rt.sh <repo> <音量> <轮数>`：真双讲，iPhone 说中文、Mac 放英文会议。`variants.sh`、`silent.sh`、`hyb.sh` 从最近一轮生成 AEC3 各种输出给 `ming.sh` 打分。
- `press.sh <repo>`：一次真实的按键整句（开同声传译、按住、手机说、松开、等说完）。

## 结果（2026-11-10，MacBook Pro，扬声器 56 %）

- 只有会议声：AEC3 0/48 英文词（参考比回声早 60–300 ms 时；ERLE 22–49 dB，约 1 秒收敛）。App 的系统声音比回声早约 40 ms，按 host time 对齐即可，再提前 80 ms 更稳。系统声音录制第一帧要约 1.7 秒才到。
- 双讲（iPhone 10 cm，一轮，Ming 打分）：VPIO 23/23 字；AEC3 默认 15/23；线性输出 23/23 但空按时 Ming 会把会议翻译出去（12 个会议词中 10 个）；混合输出 18–22/23、空按不漏会议。
- 还没做：多轮真双讲对照 App 里真正的 VPIO 按键（不是 `rec vpio`），100 % 音量，空按时 VPIO 的表现。
