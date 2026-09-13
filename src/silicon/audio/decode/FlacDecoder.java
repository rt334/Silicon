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
 * 为什么必须自己解：当前游戏内置的 SoLoud(20260903) **已经没有 flac 解码器**——
 * 实测 {@code Music.create(flac)} 直接抛 "File found, but could not be loaded"，
 * 于是 flac 既不能播、时长也探测不出来（旧代码假设的「SoLoud 能解 flac 只是 seek 坏」
 * 在现版本已不成立）。这里用 jFLAC 纯 Java 解码，完全不依赖 SoLoud 的解码能力。
 * <p>
 * 输出统一 16bit PCM WAV（小端；jFLAC 实测输出即小端）：
 * <ul>
 *   <li>位深 8/16/24 都支持，24bit 取高 16 位（Hi-Res 音源常见），不再因位深直接放弃整个文件。</li>
 *   <li>源采样率是 48k/44.1k 整数倍时（192k→48k、96k→48k、88.2k→44.1k）按整数倍做盒式平均降采样，
 *       既保质量又避免把 186s 的 192k 曲目解成 143MB WAV。</li>
 * </ul>
 * 调用顺序有坑（实测）：必须 new FLACDecoder → addPCMProcessor → decode()；先 readStreamInfo()
 * 会让 decode() 抛 "Could not find Stream Sync"。也不要调用 StreamInfo.getAudioFormat()（引用 javax.sound）。
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
    public long decodeToWav(File src, File outWav, java.util.function.IntConsumer onPercent) throws Exception {
        try (InputStream in = new BufferedInputStream(new FileInputStream(src), 1 << 16)) {
            FLACDecoder decoder = new FLACDecoder(in);
            final State st = new State(outWav, onPercent);
            final Exception[] error = new Exception[1];

            decoder.addPCMProcessor(new PCMProcessor() {
                @Override
                public void processStreamInfo(StreamInfo info) {
                    try {
                        st.init(info.getSampleRate(), info.getChannels(), info.getBitsPerSample(), info.getTotalSamples());
                    } catch (Exception e) {
                        error[0] = e;
                    }
                }

                @Override
                public void processPCM(ByteData pcm) {
                    try {
                        if (error[0] == null) st.feed(pcm.getData(), pcm.getLen());
                    } catch (Exception e) {
                        error[0] = e;
                    }
                }
            });

            decoder.decode();
            if (error[0] != null) throw error[0];
            if (!st.started) throw new IOException("no flac stream info");
            st.finish();
            return st.framesWritten;
        }
    }

    /** 解码状态机：位深转换 + 可选整数倍降采样 + 分块边界处理 */
    private static final class State {
        private final File outWav;
        private final java.util.function.IntConsumer onPercent;
        private long totalFrames;
        private int lastPercent = -1;
        private WavWriter wav;
        private int channels;
        private int bits;
        private int decimation = 1;
        private boolean started;
        long framesWritten;

        private final byte[] carry = new byte[8];
        private int carryLen;
        private short[] acc;
        private int accLen;
        private final short[] single = new short[1];
        private int sampleIndex;

        State(File out, java.util.function.IntConsumer onPercent) {
            this.outWav = out;
            this.onPercent = onPercent;
        }

        void init(int rate, int channels, int bits, long totalSamples) throws IOException {
            if (rate <= 0 || channels <= 0 || channels > 8) throw new IOException("bad flac params");
            if (bits != 8 && bits != 16 && bits != 24) throw new IOException("unsupported flac bit depth: " + bits);
            this.channels = channels;
            this.bits = bits;
            this.decimation = decimationFor(rate);
            this.started = true;
            this.totalFrames = decimation > 1 ? Math.max(1L, totalSamples / decimation) : Math.max(1L, totalSamples);
            this.acc = new short[channels * decimation * 8192];
            this.wav = new WavWriter(outWav, rate / decimation, channels);
        }

        /** 源率是 48000/44100 的整数倍时降采样，否则保持原率 */
        static int decimationFor(int rate) {
            for (int target : new int[]{48000, 44100}) {
                if (rate > target && rate % target == 0 && rate / target <= 8) return rate / target;
            }
            return 1;
        }

        void feed(byte[] data, int len) throws IOException {
            int bps = bits / 8;
            int off = 0;
            while (off < len) {
                while (carryLen < bps && off < len) carry[carryLen++] = data[off++];
                if (carryLen < bps) break;
                push(toShort(carry, 0));
                carryLen = 0;
            }
        }

        private short toShort(byte[] b, int i) {
            switch (bits) {
                case 8:
                    return (short) (b[i] << 8);                       // FLAC 8bit 有符号
                case 24:
                    return (short) ((b[i + 1] & 0xFF) | (b[i + 2] << 8)); // 24bit 小端取高 16 位
                default:
                    return (short) ((b[i] & 0xFF) | (b[i + 1] << 8));     // 16bit 小端
            }
        }

        private void push(short s) throws IOException {
            if (decimation == 1) {
                single[0] = s;
                wav.writeSamples(single, 0, 1);
                if (++sampleIndex == channels) {
                    framesWritten++;
                    sampleIndex = 0;
                    reportProgress();
                }
                return;
            }
            if (accLen == acc.length) {
                short[] bigger = new short[acc.length * 2];
                System.arraycopy(acc, 0, bigger, 0, accLen);
                acc = bigger;
            }
            acc[accLen++] = s;
            if (accLen == channels * decimation) flushGroup(decimation);
        }

        /** 盒式平均：decimation 个输入帧 → 1 个输出帧 */
        private void flushGroup(int group) throws IOException {
            short[] out = new short[channels];
            for (int c = 0; c < channels; c++) {
                int sum = 0;
                for (int k = 0; k < group; k++) sum += acc[k * channels + c];
                out[c] = (short) (sum / group);
            }
            wav.writeSamples(out, 0, channels);
            framesWritten++;
            accLen = 0;
            reportProgress();
        }

        private void reportProgress() {
            if (onPercent == null || totalFrames <= 0L) return;
            int p = (int) Math.min(100L, framesWritten * 100L / totalFrames);
            if (p != lastPercent) {
                lastPercent = p;
                onPercent.accept(p);
            }
        }

        void finish() throws IOException {
            if (decimation > 1 && accLen >= channels) {
                flushGroup(accLen / channels); // 收尾不足一组时按已有样本平均，避免丢尾巴
            }
            if (wav != null) wav.close();
        }
    }
}
