package com.glory.voice;

import java.util.ArrayList;
import java.util.List;

/**
 * 打插件包之前在桌面 JVM 上跑的自测（android_plugins/glory_voice/build_aar.ps1 调用，不过就不打包）。
 *
 * 为什么值得：编解码或者序号处理写坏了，到手机上只会表现成「声音怪」「断断续续」「偶尔咔一声」，
 * 而那时候已经分不清是网络、手机还是代码。这些逻辑不碰安卓 API，能在出包前就钉住。
 */
public final class VoiceSelfTest {
    private static int failures;

    public static void main(String[] args) {
        codecRoundTrip();
        blockDecodesAlone();
        packetFormat();
        packetizer();
        remoteStream();
        if (failures == 0) {
            System.out.println("VOICE_SELFTEST PASS");
            System.exit(0);
        }
        System.out.println("VOICE_SELFTEST FAIL failures=" + failures);
        System.exit(1);
    }

    private static void check(String name, boolean ok) {
        System.out.println((ok ? "  ok   " : "  FAIL ") + name);
        if (!ok) {
            failures++;
        }
    }

    /** 像说话一样有高有低的信号：三个频率 + 每秒起伏三次的包络。 */
    private static short[] speechLike(int frames, int phaseOffset) {
        short[] pcm = new short[frames * AdpcmCodec.FRAME_SAMPLES];
        for (int i = 0; i < pcm.length; i++) {
            double t = (i + phaseOffset) / (double) AdpcmCodec.SAMPLE_RATE;
            double env = 0.55 + 0.45 * Math.sin(2 * Math.PI * 3 * t);
            double v = env * (0.5 * Math.sin(2 * Math.PI * 220 * t)
                    + 0.3 * Math.sin(2 * Math.PI * 1100 * t)
                    + 0.12 * Math.sin(2 * Math.PI * 2900 * t));
            pcm[i] = (short) Math.round(v * 16000);
        }
        return pcm;
    }

    private static double snrDb(short[] reference, short[] decoded, int from, int to) {
        double signal = 0;
        double noise = 0;
        for (int i = from; i < to; i++) {
            double r = reference[i];
            double e = r - decoded[i];
            signal += r * r;
            noise += e * e;
        }
        if (noise == 0) {
            return 99;
        }
        return 10 * Math.log10(signal / noise);
    }

    private static void codecRoundTrip() {
        check("step table has 89 entries", AdpcmCodec.STEP_TABLE.length == 89);
        check("block is 163 bytes", AdpcmCodec.BLOCK_BYTES == 163);
        check("max packet is 494 bytes", AdpcmCodec.MAX_PACKET_BYTES == 494);
        short[] pcm = speechLike(100, 0);
        short[] out = new short[pcm.length];
        AdpcmCodec.EncoderState state = new AdpcmCodec.EncoderState();
        byte[] block = new byte[AdpcmCodec.BLOCK_BYTES];
        for (int off = 0; off < pcm.length; off += AdpcmCodec.FRAME_SAMPLES) {
            AdpcmCodec.encodeBlock(pcm, off, state, block, 0);
            AdpcmCodec.decodeBlock(block, 0, out, off);
        }
        // 跳过第一块：编码器从 0 起步，前几个采样在追信号。
        double snr = snrDb(pcm, out, AdpcmCodec.FRAME_SAMPLES, pcm.length);
        check(String.format("round-trip SNR %.1f dB >= 20", snr), snr >= 20.0);

        short[] silence = new short[AdpcmCodec.FRAME_SAMPLES];
        short[] decodedSilence = new short[AdpcmCodec.FRAME_SAMPLES];
        AdpcmCodec.EncoderState fresh = new AdpcmCodec.EncoderState();
        AdpcmCodec.encodeBlock(silence, 0, fresh, block, 0);
        AdpcmCodec.decodeBlock(block, 0, decodedSilence, 0);
        int peak = 0;
        for (short s : decodedSilence) {
            peak = Math.max(peak, Math.abs(s));
        }
        check("silence decodes to near-silence (peak " + peak + " <= 8)", peak <= 8);

        short[] loud = new short[AdpcmCodec.FRAME_SAMPLES];
        for (int i = 0; i < loud.length; i++) {
            loud[i] = (short) ((i % 2 == 0) ? 32767 : -32768);
        }
        short[] decodedLoud = new short[AdpcmCodec.FRAME_SAMPLES];
        AdpcmCodec.EncoderState extreme = new AdpcmCodec.EncoderState();
        AdpcmCodec.encodeBlock(loud, 0, extreme, block, 0);
        AdpcmCodec.decodeBlock(block, 0, decodedLoud, 0);
        check("full-scale input keeps the step index in range", extreme.index >= 0 && extreme.index <= 88);
    }

    private static void blockDecodesAlone() {
        // 连续编 10 块，只拿第 7 块单独解：模拟前面的包全丢了。
        short[] pcm = speechLike(10, 12345);
        AdpcmCodec.EncoderState state = new AdpcmCodec.EncoderState();
        byte[] block = new byte[AdpcmCodec.BLOCK_BYTES];
        byte[] seventh = new byte[AdpcmCodec.BLOCK_BYTES];
        for (int b = 0; b < 10; b++) {
            AdpcmCodec.encodeBlock(pcm, b * AdpcmCodec.FRAME_SAMPLES, state, block, 0);
            if (b == 7) {
                System.arraycopy(block, 0, seventh, 0, block.length);
            }
        }
        short[] alone = new short[pcm.length];
        AdpcmCodec.decodeBlock(seventh, 0, alone, 7 * AdpcmCodec.FRAME_SAMPLES);
        double snr = snrDb(pcm, alone, 7 * AdpcmCodec.FRAME_SAMPLES, 8 * AdpcmCodec.FRAME_SAMPLES);
        check(String.format("a block decodes on its own (SNR %.1f dB >= 20)", snr), snr >= 20.0);
    }

    private static byte[] packet(int seq, boolean spurtStart, int frames) {
        short[] pcm = speechLike(frames, seq * 7);
        AdpcmCodec.EncoderState state = new AdpcmCodec.EncoderState();
        byte[][] blocks = new byte[frames][];
        for (int i = 0; i < frames; i++) {
            blocks[i] = new byte[AdpcmCodec.BLOCK_BYTES];
            AdpcmCodec.encodeBlock(pcm, i * AdpcmCodec.FRAME_SAMPLES, state, blocks[i], 0);
        }
        return AdpcmCodec.buildPacket(seq, spurtStart, blocks, frames);
    }

    private static void packetFormat() {
        byte[] p = packet(65535, true, 2);
        check("packet length 5 + 2 x 163", p.length == 331);
        check("packet frame count", AdpcmCodec.packetFrameCount(p) == 2);
        check("packet seq survives 65535", AdpcmCodec.packetSeq(p) == 65535);
        check("packet spurt flag", AdpcmCodec.packetSpurtStart(p));
        check("no spurt flag when not set", !AdpcmCodec.packetSpurtStart(packet(3, false, 1)));

        byte[] truncated = new byte[p.length - 1];
        System.arraycopy(p, 0, truncated, 0, truncated.length);
        check("truncated packet rejected", AdpcmCodec.packetFrameCount(truncated) == -1);
        byte[] extended = new byte[p.length + 1];
        System.arraycopy(p, 0, extended, 0, p.length);
        check("oversized packet rejected", AdpcmCodec.packetFrameCount(extended) == -1);
        byte[] wrongVersion = p.clone();
        wrongVersion[0] = 9;
        check("unknown version rejected", AdpcmCodec.packetFrameCount(wrongVersion) == -1);
        byte[] lying = p.clone();
        lying[4] = 3;
        check("declared count must match the bytes", AdpcmCodec.packetFrameCount(lying) == -1);
        check("null rejected", AdpcmCodec.packetFrameCount(null) == -1);
        check("header-only rejected", AdpcmCodec.packetFrameCount(new byte[5]) == -1);
    }

    private static void packetizer() {
        final List<byte[]> sent = new ArrayList<byte[]>();
        Packetizer packetizer = new Packetizer(2, new Packetizer.Sink() {
            @Override
            public void onPacket(byte[] packet) {
                sent.add(packet);
            }
        });
        short[] frame = speechLike(1, 0);
        packetizer.startSpurt();
        for (int i = 0; i < 5; i++) {
            packetizer.add(frame);
        }
        check("2 full packets after 5 frames", sent.size() == 2);
        packetizer.flush();
        check("flush sends the partial packet", sent.size() == 3
                && AdpcmCodec.packetFrameCount(sent.get(2)) == 1);
        check("sequence numbers 0, 2, 4", AdpcmCodec.packetSeq(sent.get(0)) == 0
                && AdpcmCodec.packetSeq(sent.get(1)) == 2 && AdpcmCodec.packetSeq(sent.get(2)) == 4);
        check("only the first packet of a spurt is flagged", AdpcmCodec.packetSpurtStart(sent.get(0))
                && !AdpcmCodec.packetSpurtStart(sent.get(1)) && !AdpcmCodec.packetSpurtStart(sent.get(2)));
        packetizer.flush();
        check("flush with nothing pending sends nothing", sent.size() == 3);
        packetizer.startSpurt();
        packetizer.add(frame);
        packetizer.add(frame);
        check("next spurt is flagged and continues the sequence", sent.size() == 4
                && AdpcmCodec.packetSpurtStart(sent.get(3)) && AdpcmCodec.packetSeq(sent.get(3)) == 5);
    }

    private static void remoteStream() {
        long now = 10000;
        RemoteStream rs = new RemoteStream();
        rs.push(packet(65534, true, 1), now);
        check("buffers until 3 frames", rs.pull(now) == null && rs.queued() == 1);
        rs.push(packet(65535, false, 2), now + 20);
        check("starts playing at 3 frames", rs.pull(now + 20) != null && rs.queued() == 2);
        rs.push(packet(1, false, 2), now + 60);
        check("sequence wraparound is not loss", rs.framesLost == 0 && rs.packetsLate == 0);
        rs.push(packet(0, false, 1), now + 70);
        check("late packet dropped", rs.packetsLate == 1);
        rs.push(packet(5, false, 1), now + 100);
        check("gap counted as 2 lost frames", rs.framesLost == 2);
        rs.push(new byte[7], now + 110);
        check("malformed packet rejected", rs.packetsBad == 1);

        RemoteStream capped = new RemoteStream();
        int seq = 0;
        for (int i = 0; i < 10; i++) {
            capped.push(packet(seq, i == 0, 3), now + i);
            seq += 3;
        }
        check("queue capped at " + RemoteStream.MAX_QUEUED_FRAMES + " frames",
                capped.queued() == RemoteStream.MAX_QUEUED_FRAMES && capped.framesDropped == 10);

        RemoteStream brief = new RemoteStream();
        brief.push(packet(0, true, 2), now);
        check("short spurt waits briefly", brief.pull(now + 10) == null);
        check("short spurt plays once nothing else comes", brief.pull(now + 80) != null);

        RemoteStream under = new RemoteStream();
        under.push(packet(0, true, 3), now);
        for (int i = 0; i < 4; i++) {
            under.pull(now + 20 * i);
        }
        check("end of speech is not an underrun", under.underruns == 0);
        under.push(packet(3, false, 2), now + 100);
        check("a gap inside the same spurt is an underrun", under.underruns == 1);

        RemoteStream quiet = new RemoteStream();
        quiet.setMuted(true);
        quiet.push(packet(0, true, 3), now);
        check("muted slot queues nothing but still counts", quiet.queued() == 0 && quiet.packets == 1);

        RemoteStream idle = new RemoteStream();
        idle.push(packet(100, true, 1), now);
        idle.push(packet(40, false, 1), now + RemoteStream.IDLE_RESET_MS + 1);
        check("after a long pause an older sequence starts fresh", idle.packetsLate == 0 && idle.packets == 2);
    }
}
