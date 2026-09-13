package silicon.audio.decode;

import net.sourceforge.jaad.aac.Decoder;
import net.sourceforge.jaad.aac.SampleBuffer;
import net.sourceforge.jaad.mp4.MP4Container;
import net.sourceforge.jaad.mp4.api.AudioTrack;
import net.sourceforge.jaad.mp4.api.Frame;
import net.sourceforge.jaad.mp4.api.Movie;
import net.sourceforge.jaad.mp4.api.Track;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.util.function.IntConsumer;

/**
 * m4a / mp4 / aac 解码（JAAD，公共领域；纯 Java AAC-LC + HE-AAC + MP4 解封装）。
 * <p>
 * SoLoud 完全不认识这些格式（既无解码器也读不了非 ASCII 路径），因此这里把它们解成
 * 16bit PCM WAV 再交给 SoLoud —— 与 mp3/flac 同一条“统一解码”路径，拖动因此也是采样级精确。
 * <p>
 * 打包时已排除 jaad 中依赖 javax.sound / java.awt 的类（SPI/播放器/封面盒），只保留解码核心。
 */
public class AacDecoder implements PcmDecoder {

    @Override
    public boolean accepts(String fileName, byte[] head) {
        String n = fileName == null ? "" : fileName.toLowerCase();
        if (n.endsWith(".m4a") || n.endsWith(".mp4") || n.endsWith(".aac") || n.endsWith(".adts")) return true;
        // ISO-BMFF 的 ftyp box：偏移 4 起为 'ftyp'
        return head != null && head.length >= 12
                && head[4] == 'f' && head[5] == 't' && head[6] == 'y' && head[7] == 'p';
    }

    @Override
    public long decodeToWav(File src, File outWav, IntConsumer onPercent) throws Exception {
        try (RandomAccessFile raf = new RandomAccessFile(src, "r")) {
            MP4Container container = new MP4Container(raf);
            Movie movie = container.getMovie();
            AudioTrack track = null;
            for (Track t : movie.getTracks()) {
                if (t instanceof AudioTrack at) {
                    track = at;
                    break;
                }
            }
            if (track == null) throw new IOException("no audio track in mp4/m4a");
            byte[] asc = track.getDecoderSpecificInfo();
            if (asc == null || asc.length == 0) throw new IOException("no AAC decoder config (ASC)");
            int channels = Math.max(1, track.getChannelCount());
            int rate = track.getSampleRate();
            if (rate <= 0) throw new IOException("bad sample rate");
            Decoder decoder = new Decoder(asc);
            SampleBuffer sb = new SampleBuffer();
            sb.setBigEndian(false); // 我们的 WavWriter 写小端

            WavWriter wav = new WavWriter(outWav, rate, channels);
            long frames = 0;
            int lastPercent = -1;
            double duration = movie.getDuration();
            try {
                while (track.hasMoreFrames()) {
                    Frame frame = track.readNextFrame();
                    byte[] payload = frame.getData();
                    if (payload == null || payload.length == 0) continue;
                    decoder.decodeFrame(payload, sb);
                    byte[] pcm = sb.getData();
                    if (pcm != null && pcm.length > 0) {
                        wav.writeBytes(pcm, 0, pcm.length);
                        frames += pcm.length / (2L * channels);
                    }
                    if (onPercent != null && duration > 0) {
                        int p = (int) Math.min(100.0, frame.getTime() / duration * 100.0);
                        if (p != lastPercent) {
                            lastPercent = p;
                            onPercent.accept(p);
                        }
                    }
                }
            } finally {
                wav.close();
            }
            if (frames <= 0) throw new IOException("no AAC frames decoded");
            return frames;
        }
    }
}
