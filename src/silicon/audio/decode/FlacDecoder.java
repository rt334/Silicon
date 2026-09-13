package silicon.audio.decode;

import org.jflac.FLACDecoder;
import org.jflac.PCMProcessor;
import org.jflac.metadata.StreamInfo;
import org.jflac.util.ByteData;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;

/**
 * FLAC 解码（jFLAC，LGPL-2.1）。
 * <p>
 * SoLoud 的 flac 流式 seek 原生损坏（idSeek 后位置归零），项目原先是「短曲全量解码进内存
 * （PCM 上限约 210MB）+ 超长退流式并禁用拖动」。这里改为解成 WAV 落盘再播：内存占用恒定、
 * 拖动精确，也不再需要「600 秒」这类硬限制。
 * <p>
 * 调用顺序有坑（实测）：必须 {@code new FLACDecoder(in)} → {@code addPCMProcessor(...)} →
 * {@code decode()}；先调 {@code readStreamInfo()} 会让 decode() 抛
 * "Could not find Stream Sync"。另外不要调用 {@code StreamInfo.getAudioFormat()}，
 * 它引用 javax.sound（打包时已排除相关类）。
 */
public class FlacDecoder implements PcmDecoder {

    @Override
    public boolean accepts(String fileName, byte[] head) {
        String n = fileName == null ? "" : fileName.toLowerCase();
        if (n.endsWith(".flac")) return true;
        return head != null && head.length >= 4
                && head[0] == 'f' && head[1] == 'L' && head[2] == 'a' && head[3] == 'C';
    }

    @Override
    public long decodeToWav(File src, File outWav) throws Exception {
        try (InputStream in = new BufferedInputStream(new FileInputStream(src), 1 << 16)) {
            FLACDecoder decoder = new FLACDecoder(in);
            final WavWriter[] wav = new WavWriter[1];
            final long[] frames = new long[1];
            final Exception[] error = new Exception[1];

            decoder.addPCMProcessor(new PCMProcessor() {
                @Override
                public void processStreamInfo(StreamInfo info) {
                    try {
                        int bits = info.getBitsPerSample();
                        // 只接受 16bit：24bit 源按 16bit 写会得到噪声，宁可失败交给 FFmpeg 兜底
                        if (bits > 16) throw new IOException("unsupported flac bit depth: " + bits);
                        wav[0] = new WavWriter(outWav, info.getSampleRate(), info.getChannels());
                    } catch (Exception e) {
                        error[0] = e;
                    }
                }

                @Override
                public void processPCM(ByteData pcm) {
                    try {
                        if (wav[0] == null || error[0] != null) return;
                        wav[0].writeBytes(pcm.getData(), 0, pcm.getLen());
                        frames[0] += pcm.getLen() / (2L * Math.max(1, wav[0].channels()));
                    } catch (Exception e) {
                        error[0] = e;
                    }
                }
            });

            decoder.decode();
            if (error[0] != null) throw error[0];
            if (wav[0] == null) throw new IOException("no flac stream info");
            wav[0].close();
            return frames[0];
        }
    }
}
