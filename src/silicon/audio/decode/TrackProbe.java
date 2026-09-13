package silicon.audio.decode;

import javazoom.jl.decoder.Bitstream;
import javazoom.jl.decoder.Header;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;

/**
 * 轻量元数据探测：时长（秒）。
 * <p>
 * 为什么需要：原实现用 SoLoud 的 {@code Music.create(f)} 求时长，而当前游戏的 SoLoud
 * **已不支持 flac**——实测会对每个 flac 打一条
 * {@code [E] Failed loading music from ...: could not be loaded} 并返回 0，于是列表时长
 * 永远显示 {@code --:--}，日志还被刷屏。这里改为纯 Java 读元数据：
 * <ul>
 *   <li>FLAC：读 STREAMINFO 的 totalSamples/sampleRate（不解码，毫秒级）</li>
 *   <li>MP3：小文件逐帧扫描（只解析帧头）；大文件用首帧码率估算，避免卡主线程</li>
 * </ul>
 * 返回 -1 表示无法判定，由调用方决定是否退回其他探测方式。
 */
public class TrackProbe {
    /** 逐帧扫描的体积上限：超过则用码率估算。
     *  扫描是主线程同步调用（列表重建时每首都要算时长），16MB 全扫要几百毫秒，
     *  几十首就是数秒卡顿——实测「打开界面很慢」的主因。降到 4MB 后绝大多数曲目走
     *  码率估算（20ms，误差约 0.15%，仅用于列表显示）。 */
    private static final long SCAN_SIZE_LIMIT = 4L * 1024 * 1024;

    private TrackProbe() {}

    public static float durationSeconds(File f) {
        if (f == null || !f.isFile()) return -1f;
        byte[] head = InternalDecoders.readHead(f, 16);
        if (head == null) return -1f;
        String name = f.getName().toLowerCase();
        if (name.endsWith(".flac") || (head.length >= 4 && head[0] == 'f' && head[1] == 'L' && head[2] == 'a' && head[3] == 'C')) {
            return flacDuration(f);
        }
        if (name.endsWith(".mp3") || startsWith(head, "ID3") || mpegSync(head) >= 0) {
            return mp3Duration(f, head);
        }
        if (isMp4(head) || name.endsWith(".m4a") || name.endsWith(".mp4") || name.endsWith(".aac")) {
            float d = Mp4Demuxer.durationSeconds(f);
            if (d > 0) return d;
        }
        return -1f;
    }

    /** 是否为 ISO-BMFF（MP4/M4A）：第 4~8 字节为 ftyp */
    static boolean isMp4(byte[] head) {
        return head != null && head.length >= 8
            && head[4] == 'f' && head[5] == 't' && head[6] == 'y' && head[7] == 'p';
    }

    /** FLAC：读 STREAMINFO（注意必须用独立 decoder 实例，且只调 readStreamInfo 不调 decode） */
    static float flacDuration(File f) {
        try (InputStream in = new BufferedInputStream(new FileInputStream(f), 1 << 16)) {
            org.jflac.metadata.StreamInfo info = new org.jflac.FLACDecoder(in).readStreamInfo();
            long total = info.getTotalSamples();
            int rate = info.getSampleRate();
            if (total > 0 && rate > 0) return total / (float) rate;
        } catch (Exception ignored) {
        }
        return -1f;
    }

    /** MP3：小文件逐帧精确统计；大文件按首帧码率估算（同时跳过 ID3v2 tag） */
    static float mp3Duration(File f, byte[] head) {
        long size = f.length();
        long skip = id3v2Size(head);
        if (size - skip > SCAN_SIZE_LIMIT) return mp3Estimate(f, size - skip);
        try (InputStream in = new BufferedInputStream(new FileInputStream(f), 1 << 16)) {
            Bitstream bs = new Bitstream(in);
            long samples = 0;
            int rate = 0;
            Header h;
            while ((h = bs.readFrame()) != null) {
                rate = h.frequency();
                int perFrame = h.version() == Header.MPEG1 ? 1152 : 576;
                samples += perFrame;
                bs.closeFrame();
            }
            try {
                bs.close();
            } catch (Exception ignored) {
            }
            if (rate > 0 && samples > 0) return samples / (float) rate;
        } catch (Exception ignored) {
        }
        return -1f;
    }

    /** 用首帧码率估算时长（CBR 近似，仅供列表显示） */
    private static float mp3Estimate(File f, long audioBytes) {
        try (InputStream in = new BufferedInputStream(new FileInputStream(f), 1 << 16)) {
            Bitstream bs = new Bitstream(in);
            Header h = bs.readFrame();
            if (h == null) return -1f;
            int bitsPerSecond = h.bitrate(); // jlayer 的 bitrate() 单位是 bps（实测：16MB CBR 文件返回约 190000）
            int rate = h.frequency();
            bs.close();
            if (bitsPerSecond > 0 && rate > 0 && audioBytes > 0) {
                return (float) ((audioBytes * 8.0) / bitsPerSecond);
            }
        } catch (Exception ignored) {
        }
        return -1f;
    }

    /** ID3v2 头声明的 tag 总长度（syncsafe 整数），无则 0 */
    static long id3v2Size(byte[] head) {
        if (head == null || head.length < 10 || !startsWith(head, "ID3")) return 0;
        long size = ((head[6] & 0x7FL) << 21) | ((head[7] & 0x7FL) << 14) | ((head[8] & 0x7FL) << 7) | (head[9] & 0x7FL);
        return 10 + size;
    }

    static boolean startsWith(byte[] b, String s) {
        if (b == null || b.length < s.length()) return false;
        for (int i = 0; i < s.length(); i++) {
            if ((b[i] & 0xFF) != s.charAt(i)) return false;
        }
        return true;
    }

    /** 第一个 MPEG 帧同步位置，找不到返回 -1 */
    static int mpegSync(byte[] head) {
        if (head == null) return -1;
        for (int i = 0; i + 1 < head.length; i++) {
            if ((head[i] & 0xFF) == 0xFF && (head[i + 1] & 0xE0) == 0xE0) return i;
        }
        return -1;
    }
}
