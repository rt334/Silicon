package silicon.audio.decode;

import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;

/**
 * 内置解码器注册表：按「扩展名 + 文件头」挑选纯 Java 解码器。
 * <p>
 * 目前覆盖 mp3、flac（Soloud 能播但流式 seek 不可靠的两种）。
 * ogg/wav 由 SoLoud 原生播放（seek 表现正常），不需要在这里再解一遍；
 * m4a/aac/opus/wma 等则交给可选的 FFmpeg。
 */
public class InternalDecoders {
    private static final PcmDecoder[] DECODERS = {
            new FlacDecoder(), new Mp3Decoder(), new AacDecoder(), new OggOpusDecoder()
    };

    private InternalDecoders() {}

    /** 读取文件头若干字节（失败返回 null） */
    public static byte[] readHead(File f, int n) {
        if (f == null || !f.isFile()) return null;
        try (InputStream in = new FileInputStream(f)) {
            byte[] buf = new byte[n];
            int off = 0;
            int r;
            while (off < n && (r = in.read(buf, off, n - off)) > 0) off += r;
            if (off <= 0) return null;
            if (off == n) return buf;
            byte[] out = new byte[off];
            System.arraycopy(buf, 0, out, 0, off);
            return out;
        } catch (Exception e) {
            return null;
        }
    }

    public static boolean supports(String fileName, byte[] head) {
        for (PcmDecoder d : DECODERS) {
            if (d.accepts(fileName, head)) return true;
        }
        return false;
    }

    /**
     * 尝试用内置解码器解码。
     *
     * @return true=已成功产出 outWav；false=没有匹配的解码器或解码失败（调用方可继续尝试 FFmpeg）
     */
    public static boolean decode(File src, File outWav, String fileName, byte[] head) {
        return decode(src, outWav, fileName, head, null);
    }

    /** 带解码进度（0~100，可能回调 -1 表示未知） */
    public static boolean decode(File src, File outWav, String fileName, byte[] head, java.util.function.IntConsumer onPercent) {
        for (PcmDecoder d : DECODERS) {
            if (!d.accepts(fileName, head)) continue;
            try {
                long frames = d.decodeToWav(src, outWav, onPercent);
                return frames > 0;
            } catch (Exception e) {
                // 本包刻意不引用 arc（便于用普通 JVM 单测）；失败原因由调用方记录
                lastError = d.getClass().getSimpleName() + ": " + e.getMessage();
                return false;
            }
        }
        return false;
    }

    /** 上一次 decode 失败原因（供调用方记录/提示） */
    private static volatile String lastError;

    public static String lastError() {
        return lastError;
    }
}
