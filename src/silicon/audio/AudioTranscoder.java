package silicon.audio;

import arc.Core;
import arc.files.Fi;
import arc.util.Log;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Consumer;

/**
 * 通用音频转码器：把任意格式解码成 PCM WAV，交给 SoLoud 播放。
 * <p>
 * 为什么需要它：
 * - SoLoud（arc 内置）只解码 ogg/mp3/wav/flac，m4a/aac/alac/wma/ape… 一律播不了；
 * - 且 mp3/flac 的「流式 seek」在 SoLoud 里不可靠（flac 归零、部分 mp3 跳错位置），
 *   项目里因此堆了 streamSeekBroken / 读回校验 / 禁用拖动等一堆补丁。
 * <p>
 * 统一解法：用 FFmpeg 把源文件转成 WAV（PCM 16bit）再播。WAV 的 seek 是采样级精确，
 * 于是「所有能解码的格式」都能播放且拖动精确，不再需要按格式打补丁。
 * <p>
 * FFmpeg 是可选依赖：找不到时 {@link #isAvailable()} 返回 false，播放器退回原有行为
 * （能播 ogg/mp3/wav/flac，超出范围给出明确提示），绝不因缺失而使功能崩溃。
 * <p>
 * 线程模型：转码在单线程守护线程池上排队执行，完成后经 {@code Core.app.post} 回主线程回调；
 * 同一 hash 的并发请求会去重。转码产物落在 {@code cache/music/wav/<hash>.wav}。
 */
public class AudioTranscoder {
    /** 设置项：用户可显式指定 ffmpeg 可执行文件路径 */
    public static final String CFG_FFMPEG = "musicplayer.ffmpeg";
    /** 单次转码超时（毫秒） */
    private static final long TIMEOUT_MS = 5 * 60 * 1000L;
    /** 正在转码的 hash → 进度(0..1)，未知为 -1 */
    private static final ConcurrentHashMap<String, Float> progress = new ConcurrentHashMap<>();
    /** hash → 排队中的任务（去重） */
    private static final ConcurrentHashMap<String, Boolean> queued = new ConcurrentHashMap<>();
    /** hash → 正在运行的进程（用于取消） */
    private static final ConcurrentHashMap<String, Process> running = new ConcurrentHashMap<>();
    private static final ExecutorService pool = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "silicon-music-transcode");
        t.setDaemon(true);
        return t;
    });
    /** null=未探测，TRUE/FALSE=已探测 */
    private static Boolean available;
    private static String resolvedPath;

    private AudioTranscoder() {}

    /** 是否正在转码该 hash（供 UI 显示「转码中」） */
    public static boolean isTranscoding(String hash) {
        return hash != null && progress.containsKey(hash);
    }

    /** 转码进度 0..1；-1 表示未知 */
    public static float transcodeProgress(String hash) {
        Float p = hash == null ? null : progress.get(hash);
        return p == null ? -1f : p;
    }

    /** 解析可用的 ffmpeg：设置项 → PATH。结果缓存。 */
    public static synchronized String ffmpegPath() {
        if (available != null) return resolvedPath;
        String configured = null;
        try {
            configured = Core.settings.getString(CFG_FFMPEG, "");
        } catch (Exception ignored) {
        }
        if (configured != null && !configured.trim().isEmpty()) {
            if (probe(configured.trim())) {
                resolvedPath = configured.trim();
                available = Boolean.TRUE;
                return resolvedPath;
            }
            Log.warn("[SiliconMusic] configured ffmpeg not usable: " + configured);
        }
        // PATH 上的 ffmpeg / ffmpeg.exe
        for (String cand : new String[]{"ffmpeg", "ffmpeg.exe"}) {
            if (probe(cand)) {
                resolvedPath = cand;
                available = Boolean.TRUE;
                return resolvedPath;
            }
        }
        available = Boolean.FALSE;
        resolvedPath = null;
        return null;
    }

    public static boolean isAvailable() {
        return ffmpegPath() != null;
    }

    /** 该文件是否由「本机能力」解码成 WAV：内置纯 Java 解码器（mp3/flac）优先，
     *  其余格式只有装了 FFmpeg 才行。 */
    public static boolean canHandle(Fi src) {
        if (src == null) return false;
        try {
            java.io.File f = src.file();
            byte[] head = silicon.audio.decode.InternalDecoders.readHead(f, 16);
            if (silicon.audio.decode.InternalDecoders.supports(src.name(), head)) return true;
        } catch (Exception ignored) {
        }
        return isAvailable();
    }

    /** 重新探测（用户在设置里改了路径后调用） */
    public static synchronized void resetProbe() {
        available = null;
        resolvedPath = null;
    }

    private static boolean probe(String exe) {
        try {
            Process p = new ProcessBuilder(exe, "-version").redirectErrorStream(true).start();
            // 读掉输出，避免缓冲阻塞；1.5s 内没结束就视为不可用
            long deadline = System.currentTimeMillis() + 1500L;
            try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8))) {
                while (System.currentTimeMillis() < deadline) {
                    if (r.ready()) {
                        r.readLine();
                    } else if (!p.isAlive()) {
                        break;
                    } else {
                        Thread.sleep(20L);
                    }
                }
            }
            if (p.isAlive()) {
                p.destroyForcibly();
                return false;
            }
            return p.exitValue() == 0;
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * 请求把 src 转成 WAV（异步、按 hash 去重）。
     *
     * @param src     源文件
     * @param hash    曲目 hash（决定产物名，必须是合法十六进制；非法直接失败）
     * @param onReady 主线程回调：转码完成且产物存在
     * @param onFail  主线程回调：失败原因（已本地化前的键或文本）
     */
    public static void request(Fi src, String hash, Runnable onReady, Consumer<String> onFail) {
        if (src == null || hash == null || !MusicNetwork.isValidHash(hash)) {
            postFail(onFail, "invalid source");
            return;
        }
        // 必须与 MusicPlayer.transcodedWav 使用同一命名：<hash>.wav
        Fi out = MusicPlayer.wavCacheFile(hash + ".wav");
        if (out == null) {
            postFail(onFail, "no cache dir");
            return;
        }
        if (out.exists() && out.length() > 44) {
            if (onReady != null) Core.app.post(onReady);
            return;
        }
        String exe = ffmpegPath();
        if (exe == null && !canHandle(src)) {
            postFail(onFail, "no decoder");
            return;
        }
        if (queued.putIfAbsent(hash, Boolean.TRUE) != null) {
            return; // 已在排队/执行
        }
        progress.put(hash, -1f);
        pool.submit(() -> {
            Log.info("[Music] transcode worker start hash=" + hash + " src=" + src.absolutePath());
            Process p = null;
            try {
                Fi tmp = MusicPlayer.wavCacheFile(hash + ".part");
                if (tmp == null) throw new IllegalStateException("no tmp path");
                if (tmp.exists()) tmp.delete();
                out.parent().mkdirs();

                // 1) 纯 Java 解码器优先：mp3/flac 不需要外部程序，跨平台一致
                boolean done = false;
                try {
                    java.io.File srcFile = src.file();
                    java.io.File tmpFile = tmp.file();
                    byte[] head = silicon.audio.decode.InternalDecoders.readHead(srcFile, 16);
                    if (silicon.audio.decode.InternalDecoders.supports(src.name(), head)) {
                        progress.put(hash, 0.5f);
                        done = silicon.audio.decode.InternalDecoders.decode(srcFile, tmpFile, src.name(), head);
                    }
                } catch (Exception e) {
                    Log.warn("[SiliconMusic] internal decode error: " + e.getMessage());
                }
                Log.info("[Music] internal decode result=" + done + " hash=" + hash);
                if (!done && silicon.audio.decode.InternalDecoders.lastError() != null) {
                    Log.warn("[SiliconMusic] internal decode failed: " + silicon.audio.decode.InternalDecoders.lastError());
                }

                // 2) 内置解码器不匹配/失败 → 交给 FFmpeg（若可用）
                if (!done) {
                    if (exe == null) throw new IllegalStateException("no decoder for this format");
                    if (tmp.exists()) tmp.delete();
                    ProcessBuilder pb = new ProcessBuilder(
                            exe, "-hide_banner", "-nostdin", "-v", "error", "-y",
                            "-i", src.absolutePath(),
                            "-vn", "-map_metadata", "-1", "-c:a", "pcm_s16le",
                            "-progress", "pipe:1", "-nostats",
                            tmp.absolutePath());
                    pb.redirectErrorStream(true);
                    p = pb.start();
                    running.put(hash, p);
                    long deadline = System.currentTimeMillis() + TIMEOUT_MS;
                    try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8))) {
                        String line;
                        while ((line = r.readLine()) != null) {
                            if (line.startsWith("out_time_ms=")) {
                                try {
                                    float ms = Float.parseFloat(line.substring("out_time_ms=".length()));
                                    float total = MusicPlayer.trackLengthSeconds(hash);
                                    progress.put(hash, total > 0f ? Math.min(1f, ms / 1000f / total) : -1f);
                                } catch (Exception ignored) {
                                }
                            }
                            if (System.currentTimeMillis() > deadline) break;
                        }
                    }
                    int code = p.waitFor();
                    if (System.currentTimeMillis() > deadline) {
                        p.destroyForcibly();
                        throw new IllegalStateException("timeout");
                    }
                    if (code != 0) throw new IllegalStateException("ffmpeg exit " + code);
                }

                if (!tmp.exists() || tmp.length() <= 44) throw new IllegalStateException("empty output");
                if (out.exists()) out.delete();
                tmp.moveTo(out);
                Log.info("[Music] transcode done hash=" + hash + " bytes=" + out.length());
                progress.remove(hash);
                queued.remove(hash);
                running.remove(hash);
                if (onReady != null) Core.app.post(onReady);
            } catch (Exception e) {
                if (p != null && p.isAlive()) p.destroyForcibly();
                progress.remove(hash);
                queued.remove(hash);
                running.remove(hash);
                try {
                    Fi tmp = MusicPlayer.wavCacheFile(hash + ".part");
                    if (tmp != null && tmp.exists()) tmp.delete();
                } catch (Exception ignored) {
                }
                Log.warn("[SiliconMusic] transcode failed for " + hash + ": " + e.getMessage());
                postFail(onFail, String.valueOf(e.getMessage()));
            }
        });
    }

    /** 取消所有在途转码（世界切换 / 玩家关闭功能时调用） */
    public static void cancelAll() {
        for (Process p : running.values()) {
            try {
                if (p != null && p.isAlive()) p.destroyForcibly();
            } catch (Exception ignored) {
            }
        }
        running.clear();
        queued.clear();
        progress.clear();
    }

    private static void postFail(Consumer<String> onFail, String msg) {
        if (onFail != null) Core.app.post(() -> onFail.accept(msg));
    }
}
